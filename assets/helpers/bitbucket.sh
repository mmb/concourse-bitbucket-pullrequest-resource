#!/bin/bash

set -e

ASSETS=$(cd "$(dirname "$0")" && pwd)
source $ASSETS/helpers/utils.sh

VALUES_LIMIT=100

bitbucket_request() {
  # $1: host
  # $2: path
  # $3: query
  # $4: data
  # $5: url base path
  # $6: Skip SSL verification
  # $7: netrc file (default: $HOME/.netrc)
  # $8: HTTP method (default: POST for data, GET without data)
  # $9: recursive data for bitbucket paging

  local data="$4"
  local path=${5:-rest/api/1.0}
  local skip_ssl_verification=${6:-"false"}
  local netrc_file=${7:-$HOME/.netrc}
  local method="$8"
  local recursive=${9:-limit=${VALUES_LIMIT}}

  local request_url="${1}/${path}/${2}?${recursive}&${3}"
  local request_result=$(tmp_file_unique bitbucket-request)
  local request_data=$(tmp_file_unique bitbucket-request-data)

  # deletes the temp files
  request_result_cleanup() {
    rm -f "$request_result"
    rm -f "$request_data"
  }

  # register the cleanup function to be called on the EXIT signal
  trap request_result_cleanup EXIT

  local extra_options=""
  if [ -n "$data" ]; then
    method=${method:-POST}
    jq '.' <<< "$data" > "$request_data"
    extra_options="-H \"Content-Type: application/json\" -d @\"$request_data\""
  fi

  if [ -n "$method" ]; then
    extra_options+=" -X $method"
  fi

  if [ "$skip_ssl_verification" = "true" ]; then
    extra_options+=" -k"
  fi

  curl_cmd="curl -s --netrc-file \"$netrc_file\" $TOKEN $extra_options \"$request_url\" > \"$request_result\""
  if ! eval $curl_cmd; then
    log "Bitbucket request $request_url failed"
    exit 1
  fi

  if ! jq -c '.' < "$request_result" > /dev/null 2> /dev/null; then
    log "Bitbucket request $request_url failed (invalid JSON): $(cat "$request_result")"
    exit 1
  fi

  if [ "$(jq -r '.isLastPage' < "$request_result")" == "false" ]; then
    local nextPage=$(jq -r '.nextPageStart' < "$request_result")
    bitbucket_request "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "start=${nextPage}&limit=${VALUES_LIMIT}" > tmp.json

    jq -s -c '.[0].values + .[1]' "$request_result" "tmp.json"
  elif [ "$(jq -c '.values' < "$request_result")" != "null" ]; then
    jq -c '.values' < "$request_result"
  elif [ "$(jq -c '.errors' < "$request_result")" == "null" ]; then
    jq '.' < "$request_result"
  elif grep -q NoSuchPullRequestException "$request_result"; then
    printf "NO_SUCH_PULL_REQUEST"
    return
  elif grep -q 'This pull request has already been merged' "$request_result"; then
    printf "ALREADY_MERGED"
    return
  elif grep -q 'This pull request has been declined and must be reopened before it can be merged' "$request_result"; then
    printf "DECLINED"
    return
  else
    log "Bitbucket request ($request_url) failed: $(cat ${request_result})"
    exit 1
  fi

  # cleanup
  request_result_cleanup
}

bitbucket_pullrequest() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification
  log "Retrieving pull request #$4 for $2/$3"
  bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4" "" "" "" "$6" "$5"
}

bitbucket_pullrequest_merge() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification
  log "Retrieving pull request merge status #$4 for $2/$3"
  bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4/merge" "" "" "" "$6" "$5"
}

bitbucket_pullrequest_overview_comments() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification

  log "Retrieving pull request comments #$4 for $2/$3"
  set -o pipefail; bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4/activities" "" "" "" "$6" "$5" | \
    jq 'map(select(.action == "COMMENTED" and .commentAction == "ADDED" and .commentAnchor == null)) |
        sort_by(.createdDate) | reverse |
        map({ id: .comment.id, version: .comment.version, text: .comment.text, createdDate: .comment.createdDate })'
}

bitbucket_pullrequest_progress_msg_start() {
  # $1: pull request hash
  # $2: type
  local hash="$1"
  local type="$2"

  local build_url_job="$ATC_EXTERNAL_URL/teams/$(rawurlencode "$BUILD_TEAM_NAME")/pipelines/$(rawurlencode "$BUILD_PIPELINE_NAME")/jobs/$(rawurlencode "$BUILD_JOB_NAME")"
  echo "[*Build$type* at **[${BUILD_PIPELINE_NAME} > ${BUILD_JOB_NAME}]($build_url_job)** for $hash"
}

bitbucket_pullrequest_progress_commit_match() {
  # $1: pull request comment
  # $2: pull request hash
  # $3: type of build to match
  local comment="$1"
  local hash="$2"
  local type="$3"

  local msg=$(bitbucket_pullrequest_progress_msg_start "$hash" "$type")
  echo "$comment" | grep -Ec "^$(regex_escape "$msg")" > /dev/null
}

bitbucket_pullrequest_comment_commit_match() {
  # $1: pull request comment
  # $2: pull request hash
  local comment="$1"
  local hash="$2"

  local msg=")** for $hash into"
  echo "$comment" | grep -Ec "$(regex_escape "$msg")" > /dev/null
}

bitbucket_pullrequest_progress_comment() {
  # $1: status (success, failure or pending)
  # $2: hash of merge commit
  # $3: hash of source commit
  # $4: hash of target commit
  # $5: custom comment
  local hash="$2"

  local progress_msg_end=""
  local custom_comment=""

  if [ "$hash" == "$3" ]; then
    progress_msg_end+=" into $4]"
  else
    progress_msg_end="] $3 into $4"
  fi

  if [ -n "$5" ]; then
    custom_comment="\n\n$5"
  fi

  local build_url="$ATC_EXTERNAL_URL/teams/$(rawurlencode "$BUILD_TEAM_NAME")/pipelines/$(rawurlencode "$BUILD_PIPELINE_NAME")/jobs/$(rawurlencode "$BUILD_JOB_NAME")/builds/$(rawurlencode "$BUILD_NAME")"
  local build_result_pre=" \n\n **["
  local build_result_post="]($build_url)** - Build #$BUILD_NAME"

  case "$1" in
    success)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Finished")${progress_msg_end}${build_result_pre}✓ BUILD SUCCESS${build_result_post}${custom_comment}" ;;
    failure)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Finished")${progress_msg_end}${build_result_pre}✕ BUILD FAILED${build_result_post}${custom_comment}" ;;
    pending)
      echo "$(bitbucket_pullrequest_progress_msg_start "$hash" "Started")${progress_msg_end}${build_result_pre}&#8987; BUILD IN PROGRESS${build_result_post}${custom_comment}" ;;
  esac
}

bitbucket_pullrequest_commit_status() {
  # $1: host
  # $2: commit
  # $3: data
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification
  log "Setting pull request status $2"
  bitbucket_request "$1" "commits/$2" "" "$3" "rest/build-status/1.0" "$6" "$5"
}

bitbucket_pullrequest_add_comment_status() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: comment
  # $6: netrc file (default: $HOME/.netrc)
  # $7: skip ssl verification
  log "Adding pull request comment for status on #$4 for $2/$3"
  bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4/comments" "" "{\"text\": \"$5\" }" "" "$7" "$6"
}

bitbucket_pullrequest_update_comment_status() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: comment
  # $6: comment id
  # $7: comment version
  # $8: netrc file (default: $HOME/.netrc)
  # $9: skip ssl verification
  log "Updating pull request comment (id: $6) for status on #$4 for $2/$3"
  bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4/comments/$6" "" "{\"text\": \"$5\", \"version\": \"$7\" }" "" "$9" "$8" "PUT"
}

bitbucket_pullrequest_changes() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: netrc file (default: $HOME/.netrc)
  # $6: skip ssl verification

  log "Retrieving pull request changes #$4 for $2/$3"
  bitbucket_request "$1" "projects/$2/repos/$3/pull-requests/$4/changes" "" "" "" "$6" "$5"
}

does_pullrequest_include_changes_in_paths() {
  # $1: host
  # $2: project
  # $3: repository id
  # $4: pullrequest id
  # $5: paths
  # $6: ignore paths
  # $7: netrc file (default: $HOME/.netrc)
  # $8: skip ssl verification

  local paths=$5
  local ignore_paths=$6

  if [ -z "${paths}" -o "${paths}" == "[]" ] && \
     [ -z "${ignore_paths}" -o "${ignore_paths}" == "[]" ]; then
    echo "true"

    return
  fi

  if [ -z "${paths}" -o "${paths}" == "[]" ]; then
    paths="[\".*\"]"
  fi

  if [ -z "${ignore_paths}" ]; then
    ignore_paths="[]"
  fi

  set -e -o pipefail
  local pull_request_changes
  local changed_files
  local changed_files_that_match_paths
  local grep_arguments_for_paths

  pull_request_changes=$(bitbucket_pullrequest_changes "$1" "$2" "$3" "$4" "$7" "$8")
  changed_files=$(echo "${pull_request_changes}" | jq -r ".[] | .path.toString")
  grep_arguments_for_paths=$(get_grep_arguments_for_list "${paths}")

  set +e
  changed_files_that_match_paths="$(echo "${changed_files}" | grep ${grep_arguments_for_paths})"
  set -e

  local grep_arguments_for_ignore_paths
  grep_arguments_for_ignore_paths=$(get_grep_arguments_for_list "${ignore_paths}")

  if [ -n "${grep_arguments_for_ignore_paths}" ]; then
    set +e
    changed_files_that_match_ignore_paths=$(echo "${changed_files_that_match_paths}" | grep -v ${grep_arguments_for_ignore_paths})
    set -e
  else
    changed_files_that_match_ignore_paths="${changed_files_that_match_paths}"
  fi

  if [ -n "${changed_files_that_match_ignore_paths}" ]; then
    echo "true"
  else
    echo "false"
  fi
}

get_grep_arguments_for_list() {
  grep_arguments_for_ignore_paths=""

  for element in $(echo $1 | jq -r ".[]"); do
    grep_arguments_for_ignore_paths="${grep_arguments_for_ignore_paths} -e ${element}"
  done

  echo "${grep_arguments_for_ignore_paths}"
}
