#!/usr/bin/env bash
#
# 週次: restic forget で参照されなくなったデータの削除と、リポジトリの整合性検査。
#
set -Eeuo pipefail

LOCK=/staging/.backup.lock

log() { printf '%s [prune-gitea] %s\n' "$(date '+%F %T')" "$*"; }
die() { log "ERROR: $*"; exit 1; }

# 日次バックアップ(backup-gitea)と同じロックを使う。
# 大きなアップロードが長引いている場合は最大 3 時間待つ。
exec 9>"$LOCK"
flock -w 10800 9 || die "timed out waiting for the backup lock"

log "removing stale restic locks (if any)"
restic unlock

log "pruning unreferenced data"
restic prune --retry-lock 10m

# --read-data-subset: メタデータだけでなく、毎回ランダムに選んだ 10% の
# パックファイルを実際にダウンロードして検証する(数週間で全体を一巡)。
log "checking repository integrity"
restic check --retry-lock 10m --read-data-subset=10%

log "prune and check completed successfully"
