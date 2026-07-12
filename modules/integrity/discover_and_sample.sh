#!/usr/bin/env bash
# modules/integrity/discover_and_sample.sh
# Progressive discovery + oldest-checked resampling for one drive's checksum
# manifest, budgeted per INTEGRITY_DESIGN.md. Called from sync.sh once per
# drive per calendar day (idempotent via a lock + date stamp) so every sync
# job can call it unconditionally after a successful run without duplicating
# work. Also the engine behind 'nase integrity bootstrap' (--uncapped).
#
# Known cost: until discovery_complete, every run re-walks the whole tree
# with `find` to resume the cursor (see phase 1 below) — on this project's
# reference hardware that alone can take well over a minute on a multi-
# million-file drive. That cost is bounded to the discovery ramp-up period;
# once discovery_complete=true, phase 1 is skipped entirely and only the
# indexed SQL resample query runs.
#
# Usage: discover_and_sample.sh <mountpoint> [--uncapped]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

MOUNTPOINT="${1:-}"
UNCAPPED=false
[[ "${2:-}" == "--uncapped" ]] && UNCAPPED=true
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: discover_and_sample.sh <mountpoint> [--uncapped]"; exit 1; }

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    exit 0
fi

DB=$(integrity_db_path "$MOUNTPOINT")
[[ -f "$DB" ]] || { log_info "Integrity: no manifest at ${DB} — skipping (run apply.sh first)."; exit 0; }

STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
mkdir -p "$STAMP_DIR"

declare -a TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

# ── Once-per-day guard ────────────────────────────────────────────────────────
# Multiple sync jobs may call this for the same drive on the same night
# (e.g. up to 8 jobs all touch backup_daily). A lock avoids two invocations
# racing on the same DB; the date-stamp makes repeat calls within the same
# day free no-ops so callers never need to know whether they're "first".
# --uncapped (manual bootstrap) bypasses both — it's a deliberate one-off run.
_date_stamp=""
if [[ "$UNCAPPED" != "true" ]]; then
    _lock_name="${MOUNTPOINT#/}"
    _lock_name="${_lock_name//\//-}"
    _lock_file="${STAMP_DIR}/integrity-${_lock_name}.lock"
    exec {_INTEGRITY_LOCK_FD}>"$_lock_file"
    flock --exclusive "$_INTEGRITY_LOCK_FD"

    _date_stamp="${STAMP_DIR}/integrity-${_lock_name}.date"
    _today=$(date +%Y-%m-%d)
    if [[ -f "$_date_stamp" ]] && [[ "$(cat "$_date_stamp")" == "$_today" ]]; then
        log_info "Integrity: ${MOUNTPOINT} already sampled today — skipping."
        exit 0
    fi
fi

# Set NASE_SKIP_MOUNT_GUARDS=1 to bypass (integration tests only — same
# convention as lib/guards.sh's mount-safety checks).
if [[ "${NASE_SKIP_MOUNT_GUARDS:-}" != "1" ]]; then
    integrity_check_uuid "$MOUNTPOINT" "$DB" || exit 0
fi

# ── Config ─────────────────────────────────────────────────────────────────────
CYCLE_DAYS=$(config_get '.integrity.cycle_days');          CYCLE_DAYS="${CYCLE_DAYS:-60}"
MIN_SAMPLE=$(config_get '.integrity.min_sample');          MIN_SAMPLE="${MIN_SAMPLE:-200}"
MAX_SAMPLE=$(config_get '.integrity.max_sample');          MAX_SAMPLE="${MAX_SAMPLE:-5000}"
SKIP_RECENT=$(config_get '.integrity.skip_recent_seconds'); SKIP_RECENT="${SKIP_RECENT:-3600}"

if [[ "$UNCAPPED" == "true" ]]; then
    BUDGET=999999999
else
    BUDGET=$(integrity_budget "$DB" "$CYCLE_DAYS" "$MIN_SAMPLE" "$MAX_SAMPLE")
fi

NOW=$(date +%s)
declare -a FLAGGED_PATHS=()
hashed_count=0

# ── Phase 1: progressive discovery ──────────────────────────────────────────────
discovery_complete=$(integrity_meta_get "$DB" "discovery_complete")

if [[ "$discovery_complete" != "true" ]]; then
    tmp_list=$(mktemp); TMPFILES+=("$tmp_list")
    tmp_chunk=$(mktemp); TMPFILES+=("$tmp_chunk")

    # .nase/ itself must never be walked into: its DB is written to by this
    # very script, so indexing it would immediately "detect corruption" in
    # its own checksum on the next run. .trash/ (backup drives) holds files
    # sync.sh already treats as deleted and purges by retention age — if
    # discovery indexed them, that purge would show up here as false
    # "missing" corruption alerts.
    find "$MOUNTPOINT" -xdev \
        \( -path "${MOUNTPOINT%/}/.nase" -o -path "${MOUNTPOINT%/}/.trash" \) -prune \
        -o -type f -print 2>/dev/null > "$tmp_list"
    total=$(wc -l < "$tmp_list")
    cursor=$(integrity_meta_get "$DB" "discovery_cursor_n"); cursor="${cursor:-0}"
    # Recorded purely for the web dashboard's progress display (files
    # discovered so far / this figure) — not used by the resumption logic
    # itself, which only depends on discovery_cursor_n.
    integrity_meta_set "$DB" "discovery_total" "$total"

    if [[ "$cursor" -ge "$total" ]]; then
        integrity_meta_set "$DB" "discovery_complete" "true"
        log_info "Integrity: ${MOUNTPOINT} discovery complete (${total} files)."
    else
        chunk_size=$(( BUDGET * 4 ))
        (( chunk_size < 2000 )) && chunk_size=2000
        remaining=$(( total - cursor ))
        (( chunk_size > remaining )) && chunk_size=$remaining

        tail -n +"$((cursor + 1))" "$tmp_list" | head -n "$chunk_size" \
            | sed "s|^${MOUNTPOINT%/}/||" > "$tmp_chunk"

        candidates_sql=$(mktemp); TMPFILES+=("$candidates_sql")
        {
            echo "CREATE TEMP TABLE candidates(path TEXT PRIMARY KEY);"
            echo "BEGIN;"
            while IFS= read -r relpath; do
                [[ -n "$relpath" ]] || continue
                printf "INSERT OR IGNORE INTO candidates VALUES ('%s');\n" "$(_integrity_escape "$relpath")"
            done < "$tmp_chunk"
            echo "COMMIT;"
            # Fetch one more than BUDGET: if we get BUDGET+1 back, this
            # window still has undiscovered files beyond what we can afford
            # to hash this run, so the cursor must NOT advance past it (see
            # below) — otherwise files past the budget in a shrinking
            # window would never be discovered once discovery_complete
            # flips true.
            echo "SELECT candidates.path FROM candidates LEFT JOIN files ON files.path = candidates.path WHERE files.path IS NULL LIMIT $((BUDGET + 1));"
        } > "$candidates_sql"

        new_paths=$(sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$candidates_sql")
        new_paths_count=0
        [[ -n "$new_paths" ]] && new_paths_count=$(wc -l < <(printf '%s\n' "$new_paths"))
        window_fully_covered=true
        if [[ "$new_paths_count" -gt "$BUDGET" ]]; then
            window_fully_covered=false
            new_paths=$(printf '%s\n' "$new_paths" | head -n "$BUDGET")
        fi

        if [[ -n "$new_paths" ]]; then
            batch_sql=$(mktemp); TMPFILES+=("$batch_sql")
            echo "BEGIN;" > "$batch_sql"
            while IFS= read -r relpath; do
                [[ -n "$relpath" ]] || continue
                abspath=$(integrity_abspath "$MOUNTPOINT" "$relpath")
                [[ -f "$abspath" ]] || continue    # vanished between listing and hashing
                sum=$(integrity_sha256 "$abspath")
                [[ -n "$sum" ]] || continue         # unreadable — leave for a future pass
                st=$(stat -c '%s %Y' "$abspath" 2>/dev/null) || continue
                fsize="${st%% *}"; fmtime="${st##* }"
                esc_path=$(_integrity_escape "$relpath")
                echo "INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) VALUES ('${esc_path}', ${fsize}, ${fmtime}, '${sum}', 'ok', ${NOW}, ${NOW}, ${NOW});" >> "$batch_sql"
                (( hashed_count++ )) || true
            done <<< "$new_paths"
            echo "COMMIT;" >> "$batch_sql"
            sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$batch_sql"
        fi

        if [[ "$window_fully_covered" == "true" ]]; then
            new_cursor=$(( cursor + chunk_size ))
            integrity_meta_set "$DB" "discovery_cursor_n" "$new_cursor"
            if [[ "$new_cursor" -ge "$total" ]]; then
                integrity_meta_set "$DB" "discovery_complete" "true"
            fi
        else
            # Budget ran out before this window's undiscovered files did —
            # leave the cursor where it is so the next run rescans the same
            # window (cheaply skipping the files just inserted) instead of
            # skipping past files that were never actually indexed.
            new_cursor="$cursor"
        fi
        log_info "Integrity: ${MOUNTPOINT} discovery: indexed ${hashed_count} new file(s), cursor ${new_cursor}/${total}."
    fi
fi

# ── Phase 2: resample oldest-checked known files with any leftover budget ──────
remaining_budget=$(( BUDGET - hashed_count ))
if [[ "$UNCAPPED" != "true" ]] && [[ "$remaining_budget" -gt 0 ]]; then
    cutoff=$(( NOW - SKIP_RECENT ))
    resample_sql=$(mktemp); TMPFILES+=("$resample_sql")
    cat > "$resample_sql" <<SQL
.separator "	"
SELECT id, path, size, mtime, checksum FROM files
WHERE status='ok' AND mtime < ${cutoff}
ORDER BY last_checked ASC LIMIT ${remaining_budget};
SQL
    resample_rows=$(sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$resample_sql")

    if [[ -n "$resample_rows" ]]; then
        batch_sql=$(mktemp); TMPFILES+=("$batch_sql")
        echo "BEGIN;" > "$batch_sql"
        while IFS=$'\t' read -r id relpath rsize rmtime rchecksum; do
            [[ -n "$id" ]] || continue
            abspath=$(integrity_abspath "$MOUNTPOINT" "$relpath")
            esc_path=$(_integrity_escape "$relpath")

            if [[ ! -f "$abspath" ]]; then
                echo "UPDATE files SET status='flagged', last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                echo "INSERT INTO events (ts, path, event_type, detail) VALUES (${NOW}, '${esc_path}', 'missing', 'file no longer present at scheduled check');" >> "$batch_sql"
                FLAGGED_PATHS+=("MISSING: ${relpath}")
                continue
            fi

            st=$(stat -c '%s %Y' "$abspath" 2>/dev/null) || continue
            fsize="${st%% *}"; fmtime="${st##* }"

            if [[ "$fsize" != "$rsize" || "$fmtime" != "$rmtime" ]]; then
                # Legitimate change the reconcile hook should already have
                # caught — refresh the record silently, no alert.
                sum=$(integrity_sha256 "$abspath")
                [[ -n "$sum" ]] || continue
                echo "UPDATE files SET size=${fsize}, mtime=${fmtime}, checksum='${sum}', last_updated=${NOW}, last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                continue
            fi

            sum=$(integrity_sha256 "$abspath")
            [[ -n "$sum" ]] || continue   # unreadable this instant — try again next cycle

            if [[ "$sum" == "$rchecksum" ]]; then
                echo "UPDATE files SET last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
            else
                echo "UPDATE files SET status='flagged', last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                echo "INSERT INTO events (ts, path, event_type, detail) VALUES (${NOW}, '${esc_path}', 'mismatch', 'expected ${rchecksum} got ${sum}');" >> "$batch_sql"
                FLAGGED_PATHS+=("MISMATCH: ${relpath}")
            fi
        done <<< "$resample_rows"
        echo "COMMIT;" >> "$batch_sql"
        sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$batch_sql"
    fi
fi

# ── Alert on anything flagged this run (one batched email, not one-per-file) ───
if [[ ${#FLAGGED_PATHS[@]} -gt 0 ]]; then
    drive_label=$(basename "$MOUNTPOINT")
    {
        echo "Integrity check found ${#FLAGGED_PATHS[@]} issue(s) on ${MOUNTPOINT}:"
        echo ""
        printf '  %s\n' "${FLAGGED_PATHS[@]}"
        echo ""
        echo "Review with:      sudo nase integrity status ${drive_label}"
        echo "Acknowledge with: sudo nase integrity ack ${drive_label} <path>"
    } | "${REPO_ROOT}/modules/sync/notify.sh" \
        "NASe integrity alert: ${#FLAGGED_PATHS[@]} issue(s) on $(hostname)" || true
fi

[[ -n "$_date_stamp" ]] && date +%Y-%m-%d > "$_date_stamp"

log_ok "Integrity: ${MOUNTPOINT} run complete (discovered ${hashed_count}, budget ${BUDGET}, flagged ${#FLAGGED_PATHS[@]})."
