#!/bin/bash
#
# Nightly backup of VictoriaMetrics to Google Drive.
#
# This is the only copy of the history. Before this existed, every step count, weigh-in and
# logged set lived in exactly one Docker volume on a 1GB Nanode with nothing behind it.
#
# Runs from root's crontab at 03:00; see `install-cron.sh`.
set -euo pipefail

APP_DIR="/opt/metrics"
BACKUP_DIR="/opt/metrics-backups"
VM_DATA="/var/lib/docker/volumes/metrics_vmdata/_data"
VM_URL="http://127.0.0.1:8428"
REMOTE="gdrive:metrics-backups"
KEEP_DAYS=30
LOG_FILE="/var/log/metrics-backup.log"

# Success pings are for confirming the thing works. Set to 0 once you trust it and only
# failures will reach Discord.
NOTIFY_SUCCESS="${NOTIFY_SUCCESS:-1}"

DATE=$(date +%Y%m%d_%H%M%S)
FILE="metrics_vm_${DATE}.tar.gz"
SNAP=""

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"; }

# Builds the JSON with python3 rather than hand-escaping it into a curl argument.
# gold's backup script does the hand-escaped version and has been failing silently for
# months: its source wraps mid-string, so a real newline lands inside the JSON value and
# Discord rejects the whole payload with "invalid JSON". Never assemble JSON by hand.
notify() {
    [ -n "${DISCORD_WEBHOOK:-}" ] || { log "no DISCORD_WEBHOOK set, skipping notify"; return 0; }
    python3 -c 'import json,sys; print(json.dumps({"content": sys.argv[1]}))' "$1" \
        | curl -sS --max-time 20 -H "Content-Type: application/json" -X POST -d @- \
               "$DISCORD_WEBHOOK" >/dev/null \
        || log "WARN: Discord notify failed (backup itself is unaffected)"
}

# A snapshot is hardlinks into the same data, so leaving one behind wastes little space but
# pins the blocks it references forever. Always clean up, including on failure.
cleanup() {
    if [ -n "$SNAP" ]; then
        curl -sS --max-time 30 -XPOST "$VM_URL/snapshot/delete?snapshot=$SNAP" >/dev/null 2>&1 \
            || log "WARN: could not delete snapshot $SNAP"
    fi
}
trap cleanup EXIT

die() {
    log "ERROR: $1"
    notify "🔴 Metrics backup FAILED
Date: $(date '+%Y-%m-%d %H:%M:%S')
Error: $1"
    exit 1
}

log "Starting metrics backup..."

[ -f "$APP_DIR/.env" ] || die "$APP_DIR/.env is missing"
# shellcheck disable=SC1091
set -a; . "$APP_DIR/.env"; set +a

mkdir -p "$BACKUP_DIR"

# Snapshot rather than tarring the live directory: VictoriaMetrics is mid-merge at arbitrary
# moments and a copy taken then is not guaranteed to be loadable.
log "Creating VictoriaMetrics snapshot..."
SNAP=$(curl -sS --max-time 60 -XPOST "$VM_URL/snapshot/create" \
    | python3 -c 'import json,sys; d=json.load(sys.stdin); sys.exit(1) if d.get("status")!="ok" else print(d["snapshot"])') \
    || die "snapshot API call failed"
[ -n "$SNAP" ] || die "snapshot API returned no name"
log "Snapshot $SNAP"

[ -d "$VM_DATA/snapshots/$SNAP" ] || die "snapshot directory not found at $VM_DATA/snapshots/$SNAP"

log "Archiving..."
tar -czf "$BACKUP_DIR/$FILE" -C "$VM_DATA/snapshots" "$SNAP" || die "tar failed"
SIZE=$(du -h "$BACKUP_DIR/$FILE" | cut -f1)
log "Archive $FILE ($SIZE)"

# Prove the archive is readable before it counts as a backup. A tar that only fails on
# restore is worse than no backup, because you stop worrying about it.
tar -tzf "$BACKUP_DIR/$FILE" >/dev/null || die "archive is unreadable"

log "Uploading to $REMOTE..."
rclone copy "$BACKUP_DIR/$FILE" "$REMOTE" || die "rclone upload failed (archive kept locally)"
log "Upload complete"

log "Pruning local archives older than ${KEEP_DAYS}d..."
find "$BACKUP_DIR" -name 'metrics_vm_*.tar.gz' -mtime "+$KEEP_DAYS" -delete

if [ "$NOTIFY_SUCCESS" = "1" ]; then
    notify "🟢 Metrics backup complete
Date: $(date '+%Y-%m-%d %H:%M:%S')
File: $FILE
Size: $SIZE
Uploaded to $REMOTE"
fi

log "Backup process completed"
