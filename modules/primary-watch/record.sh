#!/usr/bin/env bash
# modules/primary-watch/record.sh
# Watches /mnt/primary recursively and appends file events to an events log
# consumed by the status report.  Managed by nase-primary-watch.service.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

EVENTS_LOG="/var/lib/nase/primary-events.log"
WATCH_PATH="/mnt/primary"
RETENTION_DAYS=90

mkdir -p "$(dirname "$EVENTS_LOG")"

# Prune entries older than RETENTION_DAYS at startup.
if [[ -f "$EVENTS_LOG" ]]; then
    cutoff=$(date -d "-${RETENTION_DAYS} days" '+%Y-%m-%d %H:%M:%S')
    tmp=$(mktemp)
    awk -F'\t' -v c="$cutoff" '$1 >= c' "$EVENTS_LOG" > "$tmp" \
        && mv "$tmp" "$EVENTS_LOG" || rm -f "$tmp"
fi

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

while IFS= read -r line; do
    raw_event="${line%% *}"
    filepath="${line#* }"

    # Skip macOS metadata noise.
    base="${filepath##*/}"
    [[ "$base" == .DS_Store ]] && continue
    [[ "$base" == ._* ]]       && continue

    op=$(normalize_event "$raw_event")
    [[ -z "$op" ]] && continue

    # MOVED_FROM on a path that still exists is an atomic save → reclassify.
    if [[ "${raw_event^^}" == "MOVED_FROM" && -e "$filepath" ]]; then
        op="modify"
    fi

    printf '%s\t%s\t%s\n' "$(date '+%Y-%m-%d %H:%M:%S')" "$op" "$filepath" \
        >> "$EVENTS_LOG"
done < <(
    inotifywait -m -r \
        --format '%e %w%f' \
        --event close_write \
        --event delete \
        --event moved_from \
        --event moved_to \
        --event create \
        "$WATCH_PATH" 2>/dev/null
)
