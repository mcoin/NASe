#!/usr/bin/env bash
# modules/integrity/reconcile-backup.sh
# Called from sync.sh after a successful rsync run. Updates both the source
# and destination drives' checksum manifests for exactly the files that
# moved this run — no separate tree walk needed, since sync.sh already knows
# what changed. Each touched file is hashed independently on both sides
# (defense-in-depth: catches corruption introduced during the copy itself,
# not just corruption at rest).
#
# Usage: reconcile-backup.sh <source_path> <dest_path> <transferred_file> <rsync_log_file>
#   source_path        the job's source dir, as passed to rsync (trailing slash)
#   dest_path          the job's dest dir, as passed to rsync (trailing slash)
#   transferred_file    one relative-to-source_path/dest_path filename per line
#                        (sync.sh's existing $transferred, from --out-format='NXFR %n')
#   rsync_log_file      sync.sh's $RSYNC_LOG — deletions are read from its
#                        "*deleting <path>" lines (rsync's default log format)
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

SOURCE_PATH="${1:-}"
DEST_PATH="${2:-}"
TRANSFERRED_FILE="${3:-}"
RSYNC_LOG_FILE="${4:-}"

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    exit 0
fi

[[ -n "$SOURCE_PATH" && -n "$DEST_PATH" ]] || { log_error "Usage: reconcile-backup.sh <source_path> <dest_path> <transferred_file> <rsync_log_file>"; exit 1; }

source_mount=$(findmnt --target "$SOURCE_PATH" --output TARGET --noheadings --first-only 2>/dev/null || true)
dest_mount=$(findmnt --target "$DEST_PATH" --output TARGET --noheadings --first-only 2>/dev/null || true)
[[ -n "$source_mount" && -n "$dest_mount" ]] || { log_info "Integrity: could not resolve mountpoints for reconcile — skipping."; exit 0; }

source_db=$(integrity_db_path "$source_mount")
dest_db=$(integrity_db_path "$dest_mount")

source_ok=false
dest_ok=false
if [[ "${NASE_SKIP_MOUNT_GUARDS:-}" == "1" ]]; then
    # Integration tests only — same convention as lib/guards.sh.
    [[ -f "$source_db" ]] && source_ok=true
    [[ -f "$dest_db" ]]   && dest_ok=true
else
    [[ -f "$source_db" ]] && integrity_check_uuid "$source_mount" "$source_db" && source_ok=true
    [[ -f "$dest_db" ]]   && integrity_check_uuid "$dest_mount" "$dest_db"   && dest_ok=true
fi

if [[ "$source_ok" != "true" && "$dest_ok" != "true" ]]; then
    exit 0
fi

source_prefix=$(integrity_relpath "$source_mount" "${SOURCE_PATH%/}")
dest_prefix=$(integrity_relpath "$dest_mount" "${DEST_PATH%/}")

NOW=$(date +%s)

# ── Upserted files (new or changed this run) ────────────────────────────────────
source_batch=""
dest_batch=""
if [[ -f "$TRANSFERRED_FILE" ]]; then
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ "$rel" == */ || "$rel" == "." ]] && continue   # directory entries, not files

        if [[ "$source_ok" == "true" ]]; then
            src_relpath="${source_prefix:+${source_prefix}/}${rel}"
            src_abspath=$(integrity_abspath "$source_mount" "$src_relpath")
            if [[ -f "$src_abspath" ]]; then
                sum=$(integrity_sha256 "$src_abspath")
                st=$(stat -c '%s %Y' "$src_abspath" 2>/dev/null || true)
                if [[ -n "$sum" && -n "$st" ]]; then
                    fsize="${st%% *}"; fmtime="${st##* }"
                    esc_path=$(_integrity_escape "$src_relpath")
                    source_batch+="INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) VALUES ('${esc_path}', ${fsize}, ${fmtime}, '${sum}', 'ok', ${NOW}, ${NOW}, ${NOW}) ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, checksum=excluded.checksum, status='ok', last_updated=${NOW}, last_checked=${NOW};"$'\n'
                fi
            fi
        fi

        if [[ "$dest_ok" == "true" ]]; then
            dst_relpath="${dest_prefix:+${dest_prefix}/}${rel}"
            dst_abspath=$(integrity_abspath "$dest_mount" "$dst_relpath")
            if [[ -f "$dst_abspath" ]]; then
                sum=$(integrity_sha256 "$dst_abspath")
                st=$(stat -c '%s %Y' "$dst_abspath" 2>/dev/null || true)
                if [[ -n "$sum" && -n "$st" ]]; then
                    fsize="${st%% *}"; fmtime="${st##* }"
                    esc_path=$(_integrity_escape "$dst_relpath")
                    dest_batch+="INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) VALUES ('${esc_path}', ${fsize}, ${fmtime}, '${sum}', 'ok', ${NOW}, ${NOW}, ${NOW}) ON CONFLICT(path) DO UPDATE SET size=excluded.size, mtime=excluded.mtime, checksum=excluded.checksum, status='ok', last_updated=${NOW}, last_checked=${NOW};"$'\n'
                fi
            fi
        fi
    done < "$TRANSFERRED_FILE"
fi

# ── Deleted files (removed from dest by rsync --delete) ─────────────────────────
# Only the destination side is updated here: a deletion means the file no
# longer exists on the source either, which is the primary drive's own
# concern (see reconcile-primary.sh, driven by primary-events.log) — this
# script only reflects what changed on the backup copy.
if [[ "$dest_ok" == "true" && -f "$RSYNC_LOG_FILE" ]]; then
    while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        [[ "$rel" == */ || "$rel" == "." ]] && continue
        dst_relpath="${dest_prefix:+${dest_prefix}/}${rel}"
        esc_path=$(_integrity_escape "$dst_relpath")
        dest_batch+="DELETE FROM files WHERE path = '${esc_path}';"$'\n'
    done < <(grep '\*deleting' "$RSYNC_LOG_FILE" 2>/dev/null | sed 's/.*\*deleting[[:space:]]*//')
fi

if [[ -n "$source_batch" ]]; then
    { echo "BEGIN;"; printf '%s' "$source_batch"; echo "COMMIT;"; } \
        | sqlite3 -bail -cmd ".timeout 30000" "$source_db"
fi
if [[ -n "$dest_batch" ]]; then
    { echo "BEGIN;"; printf '%s' "$dest_batch"; echo "COMMIT;"; } \
        | sqlite3 -bail -cmd ".timeout 30000" "$dest_db"
fi

# Refresh the dashboard's SD-card cache now, while both drives are already
# awake for this sync run — see integrity_write_status_cache in common.sh.
[[ "$source_ok" == "true" ]] && { integrity_write_status_cache "$source_mount" "$source_db" || true; }
[[ "$dest_ok"   == "true" ]] && { integrity_write_status_cache "$dest_mount" "$dest_db" || true; }

log_info "Integrity: reconciled ${SOURCE_PATH} -> ${DEST_PATH}."
