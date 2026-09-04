#!/usr/bin/env bash
# modules/primary-watch/record.sh
# Watches /mnt/primary recursively and appends file events to an events log
# consumed by the status report.  Managed by nase-primary-watch.service.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

EVENTS_LOG="${NASE_STAMP_DIR:-/var/lib/nase}/primary-events.log"
WATCH_PATH="${NASE_WATCH_PATH:-/mnt/primary}"
RETENTION_DAYS=90
# How often to record "still watching". sync.sh will not trust a quiet window
# that is not covered by a heartbeat, so this is the resolution at which the
# log can vouch for silence. Five minutes is well inside the nightly gap
# between the last heartbeat and 03:00, and costs one SD-card write.
HEARTBEAT_SECS="${NASE_WATCH_HEARTBEAT_SECS:-300}"

mkdir -p "$(dirname "$EVENTS_LOG")"

# ── Marker lines ─────────────────────────────────────────────────────────────
# The log has to answer two different questions: "what changed?" and "were you
# watching the whole time?". Without the second, silence is ambiguous — a dead
# watcher looks exactly like a quiet drive, and change detection reading this
# log would skip syncing for ever. So the log carries its own liveness:
#
#   <ts>\t__gap__\t<detail>        the watcher was not running up to <ts>
#   <ts>\t__heartbeat__\t-         the watcher was alive at <ts>
#
# Both use the same tab-separated shape as event lines and a reserved name in
# the operation column, so existing readers that filter on create/modify/delete
# ignore them.
mark() {
    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$1" "${2:--}" >> "$EVENTS_LOG"
}

# Prune entries older than RETENTION_DAYS at startup.
# Truncate and rewrite in place rather than mv: a consumer holding a cursor
# into this file must not have the inode swapped underneath it. The window
# before the oldest surviving line is unobservable afterwards, so record that
# as a gap — a reader whose cursor predates the prune has to fall back rather
# than conclude "nothing happened".
if [[ -f "$EVENTS_LOG" ]]; then
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d %H:%M:%S')
    tmp=$(mktemp)
    if awk -F'\t' -v c="$cutoff" '$1 >= c' "$EVENTS_LOG" > "$tmp"; then
        pruned=$(( $(wc -l < "$EVENTS_LOG") - $(wc -l < "$tmp") ))
        cat "$tmp" > "$EVENTS_LOG"
        (( pruned > 0 )) && mark "__gap__" "pruned ${pruned} entries older than ${RETENTION_DAYS}d"
    fi
    rm -f "$tmp"
fi

# Every start is a gap: whatever happened while this service was down was not
# recorded. Written before inotifywait is even set up, so a crash loop leaves a
# trail of gaps rather than a silent hole.
mark "__gap__" "watcher started (events during downtime were not recorded)"

# Wait for the primary drive before starting inotifywait.
until [[ -d "$WATCH_PATH" ]]; do
    log_info "Primary watch: ${WATCH_PATH} not available — waiting 30s..."
    sleep 30
done

log_info "Primary watch recorder starting (${WATCH_PATH})..."

normalize_event() {
    case "${1^^}" in
        CLOSE_WRITE|MOVED_TO) echo "modify" ;;
        DELETE|MOVED_FROM)    echo "delete" ;;
        CREATE)               echo "create" ;;
        *)                    echo ""       ;;
    esac
}

mark "__heartbeat__"
last_beat=$(date +%s)

# Read with a timeout rather than blocking, so a quiet drive still produces
# heartbeats. Keeping the heartbeat on this one thread means the log has a
# single writer and no interleaving to reason about.
while true; do
    line=""
    if IFS= read -r -t "$HEARTBEAT_SECS" line; then
        :
    else
        rc=$?
        # >128 is the read timeout — normal, just means nothing changed.
        # Anything else is EOF: inotifywait has exited and so should we.
        if (( rc <= 128 )); then
            break
        fi
    fi

    if [[ -n "$line" ]]; then
        raw_event="${line%% *}"
        filepath="${line#* }"

        # Skip macOS metadata noise.
        base="${filepath##*/}"
        if [[ "$base" != .DS_Store && "$base" != ._* ]]; then
            op=$(normalize_event "$raw_event")

            # MOVED_FROM on a path that still exists is an atomic save → reclassify.
            if [[ "${raw_event^^}" == "MOVED_FROM" && -e "$filepath" ]]; then
                op="modify"
            fi

            [[ -n "$op" ]] && printf '%s\t%s\t%s\n' \
                "$(date '+%Y-%m-%d %H:%M:%S')" "$op" "$filepath" >> "$EVENTS_LOG"
        fi
    fi

    now_epoch=$(date +%s)
    if (( now_epoch - last_beat >= HEARTBEAT_SECS )); then
        mark "__heartbeat__"
        last_beat=$now_epoch
    fi
done < <(
    # .nase/ (the integrity manifest, root:root 0700) and .trash/ must never
    # surface here: reconcile-primary.sh consumes this log and would try to
    # hash the manifest DB itself, and the web dashboard's changes page would
    # show its internal churn (e.g. bootstrap scratch files) as if it were
    # user activity. --exclude keeps inotifywait from even watching those
    # subtrees, same intent as discover_and_sample.sh's `find -prune`.
    inotifywait -m -r \
        --format '%e %w%f' \
        --exclude '/\.(nase|trash)(/|$)' \
        --event close_write \
        --event delete \
        --event moved_from \
        --event moved_to \
        --event create \
        "$WATCH_PATH"
) || {
    status=$?
    log_error "inotifywait exited with status ${status} — watch setup likely failed (e.g. fs.inotify.max_user_watches too low for the directory count under ${WATCH_PATH})."
    exit "$status"
}
