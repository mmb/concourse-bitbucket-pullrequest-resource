#!/bin/bash

export TMPDIR=${TMPDIR:-/tmp}

hash() {
  sha=$(which sha256sum || which shasum)
  echo "$1" | $sha | awk '{ print $1 }'
}

contains_element() {
  local e
  for e in "${@:2}"; do [[ "$e" == "$1" ]] && return 0; done
  return 1
}

hide_password() {
  if ! echo "$1" | jq -c '.' > /dev/null 2> /dev/null; then
    echo "(invalid json: $1)>"
    exit 1
  fi

  local paths=$(echo "${1:-{\} }" | jq -c "paths")
  local query=""
  if [ -n "$paths" ]; then
    while read path; do
      local parts=$(echo "$path" | jq -r '.[]')
      local selection=""
      local found=""
      while read part; do
        selection+=".$part"
        if [ "$part" == "password" ]; then
          found="true"
        fi
      done <<< "$parts"

      if [ -n "$found" ]; then
        query+=" | jq -c '$selection = \"*******\"'"
      fi
    done <<< "$paths"
  fi

  local json="${1//\"/\\\"}"
  eval "echo \"$json\" $query"
}

log() {
  # $1: message
  # $2: json
  local message="$(date -u '+%F %T') - $1"
  if [ -n "$2" ]; then
   message+=" - $(hide_password "$2")"
  fi
  echo -e "$message" >&2
}

tmp_file() {
  echo "$TMPDIR/bitbucket-pullrequest-resource-$1"
}

tmp_file_unique() {
  mktemp "$TMPDIR/bitbucket-pullrequest-resource-$1.XXXXXX"
}

#
# URI parsing function
#
# The function creates global variables with the parsed results.
# It returns 0 if parsing was successful or non-zero otherwise.
#
# [schema://][user[:password]@]host[:port][/path][?[arg1=val1]...][#fragment]
#
# Reference: http://wp.vpalos.com/537/uri-parsing-using-bash-built-in-features/
#
uri_parser() {
    # uri capture
    uri="$@"

    # safe escaping
    uri="${uri//\`/%60}"
    uri="${uri//\"/%22}"

    # top level parsing
    pattern='^(([a-z]{3,5})://)?((([^:\/]+)(:([^@\/]*))?@)?([^:\/?]+)(:([0-9]+))?)(\/[^?]*)?(\?[^#]*)?(#.*)?$'
    [[ "$uri" =~ $pattern ]] || return 1;

    # component extraction
    uri=${BASH_REMATCH[0]}
    uri_schema=${BASH_REMATCH[2]}
    uri_address=${BASH_REMATCH[3]}
    uri_user=${BASH_REMATCH[5]}
    uri_password=${BASH_REMATCH[7]}
    uri_host=${BASH_REMATCH[8]}
    uri_port=${BASH_REMATCH[10]}
    uri_path=${BASH_REMATCH[11]}
    uri_query=${BASH_REMATCH[12]}
    uri_fragment=${BASH_REMATCH[13]}

    # path parsing
    count=0
    path="$uri_path"
    pattern='^/+([^/]+)'
    while [[ $path =~ $pattern ]]; do
        eval "uri_parts[$count]=\"${BASH_REMATCH[1]}\""
        path="${path:${#BASH_REMATCH[0]}}"
        count=$((count + 1))
    done

    # query parsing
    count=0
    query="$uri_query"
    pattern='^[?&]+([^= ]+)(=([^&]*))?'
    while [[ $query =~ $pattern ]]; do
        eval "uri_args[$count]=\"${BASH_REMATCH[1]}\""
        eval "uri_arg_${BASH_REMATCH[1]}=\"${BASH_REMATCH[3]}\""
        query="${query:${#BASH_REMATCH[0]}}"
        count=$((count + 1))
    done

    # return success
    return 0
}

date_from_epoch_seconds() {
  # Mac OS X:
  #date -r $1
  date -d @$1
}

# http://stackoverflow.com/questions/296536/how-to-urlencode-data-for-curl-command
rawurlencode() {
  local string="${1}"
  local strlen=${#string}
  local encoded=""
  local pos c o

  for (( pos=0 ; pos<strlen ; pos++ )); do
     c=${string:$pos:1}
     case "$c" in
        [-_.~a-zA-Z0-9] ) o="${c}" ;;
        * )               printf -v o '%%%02x' "'$c"
     esac
     encoded+="${o}"
  done

  echo "${encoded}"
}

regex_escape() {
  echo "$1" | sed 's/[^^]/[&]/g; s/\^/\\^/g'
}

getBasePathOfBitbucket() {
  # get base path in case bitbucket does not run on /

  local base_path=""
  for i in "${!uri_parts[@]}"
  do
    if [ ${uri_parts[$i]} = "scm" ]; then
      break
    fi

    base_path=$base_path"/"${uri_parts[$i]}
  done

  echo ${base_path}
}
