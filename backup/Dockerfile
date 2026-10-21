FROM alpine:3.22

RUN apk add --no-cache \
  bash \
  ca-certificates \
  coreutils \
  docker-cli \
  restic \
  tzdata \
  util-linux

COPY --chmod=700 backup.sh /usr/local/bin/backup-gitea
COPY --chmod=700 prune.sh  /usr/local/bin/prune-gitea
COPY crontab /etc/crontabs/root

CMD ["crond", "-f", "-l", "2"]
