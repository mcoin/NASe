#!/usr/bin/env bash
# modules/watch/watch.sh
# Long-running watcher: sends a notification whenever a watched path sees a
# configured event (modify / delete / create).  Managed by nase-watch.service.
#
# File paths are watched via their parent directory so that atomic saves
# (write-to-temp + rename, as macOS/Samba does) are always detected.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

NOTIFY="${REPO_ROOT}/modules/sync/notify.sh"
STAMP_DIR="/var/lib/nase"
COOLDOWN=60   # minimum seconds between notifications for the same watch entry

count=$(config_len '.file_watch')
if [[ "$count" -eq 0 ]]; then
    log_info "No file_watch entries configured — exiting."
    exit 0
fi

# Load all watch entries into parallel arrays.
declare -a W_PATHS=()
declare -a W_LABELS=()
declare -a W_EVENTS=()   # comma-separated user-facing event types per entry

for i in $(seq 0 $((count - 1))); do
    W_PATHS+=("$(config_idx '.file_watch' "$i" '.path')")
    W_LABELS+=("$(config_idx '.file_watch' "$i" '.label')")
    events=$(yq eval ".file_watch[${i}].events[]" "$CONFIG_FILE" 2>/dev/null \
             | tr '\n' ',' | sed 's/,$//')
    W_EVENTS+=("$events")
done

# Build inotifywait targets: watch the parent directory for file paths so that
# atomic renames (used by most editors and Samba) don't cause the watch to miss
# events after the first save. Watch the directory itself for directory paths.
declare -a WATCH_TARGETS=()
declare -A SEEN_TARGETS=()
for i in $(seq 0 $((count - 1))); do
    path="${W_PATHS[$i]}"
    if [[ -d "$path" ]]; then
        target="$path"
    else
        target="$(dirname "$path")"
    fi
    if [[ -z "${SEEN_TARGETS[$target]+_}" ]]; then
        SEEN_TARGETS[$target]=1
        WATCH_TARGETS+=("$target")
    fi
done

log_info "Watching ${count} path(s):"
for i in $(seq 0 $((count - 1))); do
    log_info "  [${i}] ${W_PATHS[$i]}  (${W_LABELS[$i]})  events: ${W_EVENTS[$i]}"
done

# Map a raw inotify event name to one of the user-facing types.
normalize_event() {
    case "${1^^}" in
        MODIFY|CLOSE_WRITE) echo "modify" ;;
        DELETE|MOVED_FROM)  echo "delete" ;;
        CREATE|MOVED_TO)    echo "create" ;;
        *)                  echo ""       ;;
    esac
}

# Send a notification, but no more than once per COOLDOWN seconds per entry.
notify_with_cooldown() {
    local idx="$1" subject="$2" body="$3"
    local stamp="${STAMP_DIR}/watch-${idx}.stamp"
    local now; now=$(date +%s)
    if [[ -f "$stamp" ]]; then
        local last; last=$(cat "$stamp")
        if (( now - last < COOLDOWN )); then
            return 0
        fi
    fi
    echo "$now" > "$stamp"
    "$NOTIFY" "$subject" "$body" || true
}

# Process substitution keeps the arrays visible (avoids a subshell via pipe).
while IFS= read -r line; do
    # inotifywait --format '%e %w%f' → "EVENT[,EVENT2] /full/path"
    raw_event="${line%% *}"
    filepath="${line#* }"
    event="${raw_event%%,*}"   # take first token if combined (e.g. MODIFY,CLOSE_WRITE)

    normalized=$(normalize_event "$event")
    [[ -z "$normalized" ]] && continue

    # MOVED_FROM on a watched path is an atomic save (macOS/Samba renames the
    # old file away before writing the new one). If the file already exists
    # again, reclassify as modify so it isn't reported as a deletion.
    if [[ "$event" == "MOVED_FROM" && -e "$filepath" ]]; then
        normalized="modify"
    fi

    for i in $(seq 0 $((count - 1))); do
        [[ "$filepath" == "${W_PATHS[$i]}"* ]] || continue

        IFS=',' read -ra configured <<< "${W_EVENTS[$i]}"
        matched=false
        for ev in "${configured[@]}"; do
            [[ "${ev// /}" == "$normalized" ]] && { matched=true; break; }
        done
        [[ "$matched" == true ]] || continue

        subject="[NASe] File ${normalized}: ${W_LABELS[$i]}"
        body="Event:  ${event}
File:   ${filepath}
Watch:  ${W_LABELS[$i]} (${W_PATHS[$i]})
Time:   $(date '+%Y-%m-%d %H:%M:%S')"

        log_info "File ${normalized}: ${filepath}  (${W_LABELS[$i]})"
        notify_with_cooldown "$i" "$subject" "$body"
        break
    done
done < <(
    inotifywait -m -r \
        --format '%e %w%f' \
        --event modify \
        --event close_write \
        --event delete \
        --event moved_from \
        --event moved_to \
        --event create \
        "${WATCH_TARGETS[@]}" 2>/dev/null
)
