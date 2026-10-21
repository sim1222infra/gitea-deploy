#!/usr/bin/env bash
#
# Gitea のデータディレクトリ(ファイル群のみ。DB は別系統でバックアップ済み)を
# Btrfs の reflink で瞬間コピーし、restic でリモートリポジトリへアップロードする。
#
# 流れ:
#   1. ロック取得・健全性チェック・restic リポジトリ確認(未作成なら init)
#   2. watchdog コンテナ起動
#      → 本スクリプトが途中で死んでも(SIGKILL / OOM / コンテナ再作成)
#        一定時間後に Gitea を必ず再開させる保険
#   3. Gitea 停止
#   4. cp --reflink=always で /source/gitea → /staging/current へ瞬間コピー
#   5. Gitea 再開 → watchdog 破棄  (Gitea 停止はここまで。通常 1〜2 分)
#   6. restic backup + forget   (prune と check は週次の prune-gitea で実施)
#
set -Eeuo pipefail

SOURCE=/source/gitea
STAGING_ROOT=/staging
STAGING=$STAGING_ROOT/current
LOCK=$STAGING_ROOT/.backup.lock
# restic backup 実行中だけ存在するマーカー。残っていれば前回が途中で死んだ証拠。
IN_PROGRESS=$STAGING_ROOT/.restic-backup-in-progress

RESTIC_HOST=${RESTIC_HOST:-dell-server}
RESTIC_TAG=${RESTIC_TAG:-gitea}

# Gitea 停止から再開までの上限時間(秒)。超えたら watchdog が強制的に起動する。
WATCHDOG_TIMEOUT=${WATCHDOG_TIMEOUT:-900}
WATCHDOG_NAME=${WATCHDOG_NAME:-gitea-backup-watchdog}
WATCHDOG_IMAGE=${WATCHDOG_IMAGE:-docker:cli}

log() { printf '%s [backup-gitea] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

: "${GITEA_CONTAINER:?GITEA_CONTAINER is not set}"
: "${RESTIC_REPOSITORY:?RESTIC_REPOSITORY is not set}"

# ---------------------------------------------------------------------------
# ロック(prune-gitea と共有)
# ---------------------------------------------------------------------------
exec 9>"$LOCK"
if ! flock -n 9; then
    log "another backup/prune is already running, skipping"
    exit 0
fi

# ---------------------------------------------------------------------------
# 健全性チェック
#   マウント漏れや空ディレクトリを「正常なバックアップ」として取り込み、
#   retention で正常な世代を押し出してしまう事故を防ぐ。
# ---------------------------------------------------------------------------
mountpoint -q "$STAGING_ROOT" \
    || die "$STAGING_ROOT is not a mount point (volume missing?)"
[[ -d $SOURCE/repositories && -f $SOURCE/gitea/conf/app.ini ]] \
    || die "$SOURCE does not look like a Gitea data directory (disk not mounted?)"
docker inspect --format '{{.State.Status}}' "$GITEA_CONTAINER" >/dev/null \
    || die "cannot find container $GITEA_CONTAINER (docker.sock not mounted or name changed?)"

# ---------------------------------------------------------------------------
# restic リポジトリ確認(Gitea を止める前に認証・疎通エラーを検出する)
#   restic 0.17+ は「リポジトリ未作成」を終了コード 10 で返す。
# ---------------------------------------------------------------------------
rc=0
restic cat config >/dev/null 2>&1 || rc=$?
case $rc in
    0)  ;;
    10) log "restic repository not found, initializing"
        restic init ;;
    *)  die "cannot access restic repository (restic exit code $rc)" ;;
esac

# 前回の実行が強制終了されると restic のロックが残り、forget/prune が
# 「repository is already locked」で失敗する。restic へのアクセスは
# このコンテナから flock 直列で行うので、古いロックの掃除は安全。
log "removing stale restic locks (if any)"
restic unlock

# 前回の restic backup が途中で強制終了(OOM 等)された場合:
#   アップロード済みのパックはリポジトリに残っているが、最後の index 保存以降の
#   分は index に載っていない。repair index で index に取り込んでおくと、
#   今回の backup がそれらを再利用でき、check でも「未参照パック」にならない。
if [[ -e $IN_PROGRESS ]]; then
    log "previous restic backup was interrupted; repairing index to reuse uploaded data"
    restic repair index
    rm -f "$IN_PROGRESS"
fi

# ---------------------------------------------------------------------------
# Gitea 停止/再開と watchdog
# ---------------------------------------------------------------------------
gitea_stopped=0
watchdog_started=0

start_gitea() {
    if (( gitea_stopped )); then
        log "starting Gitea ($GITEA_CONTAINER)"
        if docker start "$GITEA_CONTAINER" >/dev/null; then
            gitea_stopped=0
        else
            log "ERROR: failed to start Gitea, watchdog will retry in <= ${WATCHDOG_TIMEOUT}s"
        fi
    fi
}

stop_watchdog() {
    if (( watchdog_started )); then
        docker rm -f "$WATCHDOG_NAME" >/dev/null 2>&1 || true
        watchdog_started=0
    fi
}

cleanup() {
    local rc=$?
    start_gitea
    # Gitea の起動に失敗した場合は watchdog を残して再試行させる
    if (( gitea_stopped == 0 )); then
        stop_watchdog
    fi
    if (( rc != 0 )); then
        log "backup FAILED (exit code $rc); staging copy left at $STAGING for inspection"
    fi
    exit "$rc"
}
trap cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

log "removing previous staging copy"
rm -rf "$STAGING"
mkdir -p "$STAGING"

log "starting watchdog ($WATCHDOG_IMAGE): will 'docker start $GITEA_CONTAINER' after ${WATCHDOG_TIMEOUT}s"
docker rm -f "$WATCHDOG_NAME" >/dev/null 2>&1 || true
docker run -d --rm --name "$WATCHDOG_NAME" \
    -v /var/run/docker.sock:/var/run/docker.sock \
    "$WATCHDOG_IMAGE" \
    sh -c "sleep $WATCHDOG_TIMEOUT && docker start $GITEA_CONTAINER" >/dev/null
watchdog_started=1

log "stopping Gitea ($GITEA_CONTAINER)"
gitea_stopped=1   # stop の途中で死んでも cleanup が start を試みるよう先に立てる
docker stop --time 60 "$GITEA_CONTAINER" >/dev/null

log "creating Btrfs reflink copy: $SOURCE -> $STAGING"
# --reflink=always: reflink できない環境(別FS・非Btrfs)では 67GB の
# 通常コピーに化けず、エラーで止まる。
cp -a --reflink=always "$SOURCE"/. "$STAGING"/

# Gitea 停止中に取った整合点の記録
date --iso-8601=seconds > "$STAGING/.backup-consistent-at"

start_gitea
stop_watchdog
log "Gitea is running again; downtime finished"

# ---------------------------------------------------------------------------
# restic
# ---------------------------------------------------------------------------
log "uploading snapshot with restic"
# staging は毎回 cp -a で作り直すため inode と ctime が必ず変わる。
# これらを無視しないと restic が毎日 67GB を全部読み直すので、
# 変更検知は mtime + サイズ(cp -a で保持される)で行う。
touch "$IN_PROGRESS"
restic backup "$STAGING" \
    --tag "$RESTIC_TAG" \
    --host "$RESTIC_HOST" \
    --ignore-inode \
    --ignore-ctime
rm -f "$IN_PROGRESS"

log "applying retention policy"
restic forget \
    --retry-lock 10m \
    --tag "$RESTIC_TAG" \
    --host "$RESTIC_HOST" \
    --keep-daily 14 \
    --keep-weekly 8 \
    --keep-monthly 12

log "removing staging copy"
rm -rf "$STAGING"

log "backup completed successfully"
