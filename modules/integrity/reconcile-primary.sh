#!/usr/bin/env bash
# modules/integrity/reconcile-primary.sh
# Updates primary's checksum manifest from /var/lib/nase/primary-events.log —
# the event log already written by the existing nase-primary-watch.service
# (modules/primary-watch/record.sh, inotify-based). No separate tree walk or
# rsync hook needed: every create/modify/delete under /mnt/primary is already
# recorded there in real time; this just consumes what's new since the last
# run.
#
# Cursor: meta.primary_events_cursor stores the exact text of the last line
# processed (not a byte offset or line count) because primary-events.log is
# periodically rewritten by record.sh to prune entries older than 90 days.
# If that exact line is still present, resume right after it. If it's gone
# (only possible if this script hasn't run in 90+ days), reprocessing the
# whole log from the start is safe — every operation here is idempotent
# (upsert / delete-if-present) — so the fallback just redoes some old work
# once rather than silently skipping events.
#
# Usage: reconcile-primary.sh <primary-mountpoint>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

MOUNTPOINT="${1:-}"
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: reconcile-primary.sh <primary-mountpoint>"; exit 1; }

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    exit 0
fi

EVENTS_LOG="${NASE_PRIMARY_EVENTS_LOG:-/var/lib/nase/primary-events.log}"
[[ -f "$EVENTS_LOG" ]] || { log_info "Integrity: ${EVENTS_LOG} not found — nase-primary-watch may not have run yet."; exit 0; }

DB=$(integrity_db_path "$MOUNTPOINT")
[[ -f "$DB" ]] || { log_info "Integrity: no manifest at ${DB} — skipping."; exit 0; }

if [[ "${NASE_SKIP_MOUNT_GUARDS:-}" != "1" ]]; then
    integrity_check_uuid "$MOUNTPOINT" "$DB" || exit 0
fi

cursor_line=$(integrity_meta_get "$DB" "primary_events_cursor")

start_line=1
if [[ -n "$cursor_line" ]]; then
    found_at=$(grep -n -F -x -- "$cursor_line" "$EVENTS_LOG" | tail -1 | cut -d: -f1 || true)
    if [[ -n "$found_at" ]]; then
        start_line=$(( found_at + 1 ))
    else
        log_warn "Integrity: primary-events.log cursor not found (log was likely pruned) — reprocessing from the start."
    fi
fi

new_lines_file=$(mktemp)
trap 'rm -f "$new_lines_file"' EXIT
tail -n +"$start_line" "$EVENTS_LOG" > "$new_lines_file"

if [[ ! -s "$new_lines_file" ]]; then
    exit 0
fi

NOW=$(date +%s)
batch_sql=$(mktemp)
trap 'rm -f "$new_lines_file" "$batch_sql"' EXIT
echo "BEGIN;" > "$batch_sql"

last_line=""
processed=0
while IFS=$'\t' read -r ts op filepath; do
    [[ -n "$filepath" ]] || continue
    last_line="${ts}	${op}	${filepath}"

    case "$filepath" in
        "${MOUNTPOINT%/}"/*) ;;
        *) continue ;;   # event under a different watch root than requested
    esac
    case "$filepath" in
        "${MOUNTPOINT%/}/.nase"|"${MOUNTPOINT%/}/.nase/"*|"${MOUNTPOINT%/}/.trash"|"${MOUNTPOINT%/}/.trash/"*)
            continue ;;   # never index the manifest's own files — see discover_and_sample.sh
    esac
    relpath=$(integrity_relpath "$MOUNTPOINT" "$filepath")
    esc_path=$(_integrity_escape "$relpath")

    case "$op" in
        delete)
            echo "DELETE FROM files WHERE path = '${esc_path}';" >> "$batch_sql"
            ;;
        create|modify)
            if [[ -f "$filepath" ]]; then
                sum=$(integrity_sha256 "$filepath")
                st=$(stat -c '%s %Y' "$filepath" 2>/dev/null || true)
                if [[ -n "$sum" && -n "$st" ]]; then
                    fsize="${st%% *}"; fmtime="${st##* }"
                    echo "INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) VALUES ('${esc_path}', ${fsize}, ${fmtime}, '${sum}', 'ok', ${NOW}, ${NOW}, ${NOW}) ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, checksum=excluded.checksum, status='ok', last_updated=${NOW}, last_checked=${NOW};" >> "$batch_sql"
                fi
                # else: already gone by the time we processed it — a later
                # event for the same path will reflect current reality.
            fi
            ;;
    esac
    (( processed++ )) || true
done < "$new_lines_file"

echo "COMMIT;" >> "$batch_sql"

if [[ "$processed" -gt 0 ]]; then
    sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$batch_sql"
fi
if [[ -n "$last_line" ]]; then
    integrity_meta_set "$DB" "primary_events_cursor" "$last_line"
fi

log_info "Integrity: ${MOUNTPOINT} reconciled ${processed} event(s) from primary-events.log."
