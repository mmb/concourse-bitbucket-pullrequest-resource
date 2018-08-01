FROM alpine:3.8

RUN apk --no-cache add \
  bash=4.4.19-r1 \
  ca-certificates=20171114-r3 \
  curl=7.61.0-r0 \
  git=2.18.0-r0 \
  jq=1.6_rc1-r1 \
  openssh-client=7.7_p1-r2

# can't `git pull` unless we set these
RUN git config --global user.email "git@localhost" && \
    git config --global user.name "git"

COPY scripts/install_git_lfs.sh install_git_lfs.sh
RUN ./install_git_lfs.sh

COPY assets /opt/resource
