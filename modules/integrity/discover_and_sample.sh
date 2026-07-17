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
# Usage: discover_and_sample.sh <mountpoint> [--uncapped [limit]]
# A LIMIT after --uncapped caps this invocation to that many newly-hashed
# files instead of draining the whole remaining backlog — see bootstrap.sh.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

MOUNTPOINT="${1:-}"
UNCAPPED=false
UNCAPPED_LIMIT=""
if [[ "${2:-}" == "--uncapped" ]]; then
    UNCAPPED=true
    UNCAPPED_LIMIT="${3:-}"
fi
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: discover_and_sample.sh <mountpoint> [--uncapped [limit]]"; exit 1; }

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    exit 0
fi

DB=$(integrity_db_path "$MOUNTPOINT")
[[ -f "$DB" ]] || { log_info "Integrity: no manifest at ${DB} — skipping (run apply.sh first)."; exit 0; }

STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
mkdir -p "$STAMP_DIR"

# Scratch files (the full per-drive file listing plus SQL batches) live under
# .nase/tmp on the drive itself, not system /tmp. /tmp is a RAM-backed tmpfs
# sized off the Pi's total RAM (commonly ~1-2G) — a plain `find` listing of a
# multi-million-file, multi-terabyte drive can already exceed that on its
# own, so scratch space needs to scale with the drive, not the Pi. .nase/tmp
# sits inside the already-pruned ".nase" path (see phase 1 below), so it's
# automatically excluded from being walked/hashed.
SCRATCH_DIR="${MOUNTPOINT%/}/.nase/tmp"
mkdir -p "$SCRATCH_DIR"
chmod 0700 "$SCRATCH_DIR"
# Unlike /tmp, this doesn't get cleared by a reboot — sweep anything a prior
# run left behind (e.g. killed mid-run) before adding this run's own files.
find "$SCRATCH_DIR" -mindepth 1 -maxdepth 1 -type f -delete

declare -a TMPFILES=()
trap 'rm -f "${TMPFILES[@]}"' EXIT

# ── Cross-mode lock ───────────────────────────────────────────────────────────
# One drive, one discover_and_sample.sh writer at a time — a regular
# (per-sync-job) call and a manual --uncapped bootstrap must never touch the
# same drive's DB concurrently (a bootstrap's multi-hour transaction racing a
# same-night nightly pass is exactly what corrupted a COMMIT once before).
# Neither side ever blocks waiting for the other — whichever call loses the
# race is simply cancelled outright: a regular call skips for the night (it
# resumes tomorrow, and a sync job must never stall behind an hours-long
# bootstrap); a bootstrap exits with an error telling the operator to re-run
# once the nightly pass — a few minutes at most — has finished.
_lock_name="${MOUNTPOINT#/}"
_lock_name="${_lock_name//\//-}"
_lock_file="${STAMP_DIR}/integrity-${_lock_name}.lock"
exec {_INTEGRITY_LOCK_FD}>"$_lock_file"
if ! flock --exclusive --nonblock "$_INTEGRITY_LOCK_FD"; then
    if [[ "$UNCAPPED" == "true" ]]; then
        log_error "Integrity: ${MOUNTPOINT} has a regular pass in progress — cancelling bootstrap. Try again shortly."
        exit 1
    else
        log_info "Integrity: ${MOUNTPOINT} bootstrap in progress — cancelling tonight's pass."
        exit 0
    fi
fi

# ── Once-per-day guard ────────────────────────────────────────────────────────
# Multiple sync jobs may call this for the same drive on the same night
# (e.g. up to 8 jobs all touch backup_daily). The date-stamp makes repeat
# calls within the same day free no-ops so callers never need to know
# whether they're "first". --uncapped (manual bootstrap) bypasses this —
# it's a deliberate one-off run, not the nightly budgeted pass.
_date_stamp=""
if [[ "$UNCAPPED" != "true" ]]; then
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

# Fixed checkpoint size for the hashing loop below (not config-driven — this
# just bounds how much work a crash mid-run can lose; nightly capped runs are
# already well under this, it only matters for large --uncapped batches).
COMMIT_BATCH_SIZE=2000

# Files per integrity_batch_hash() call (not config-driven, same rationale
# as COMMIT_BATCH_SIZE) — forking `stat`/`sha256sum` once per file was the
# dominant cost of a large --uncapped pass (a 200000-file run forked 400000
# processes just for this step). Batching cuts that by ~this factor.
HASH_BATCH_SIZE=500

_MP_PREFIX="${MOUNTPOINT%/}/"

if [[ "$UNCAPPED" == "true" ]]; then
    # A bounded bootstrap run (--uncapped N) still hashes at full speed with
    # no once-per-day guard, but stops after N new files so a multi-million
    # file backlog can be worked through in safe, resumable increments
    # (e.g. one run a day) instead of a single all-or-nothing pass.
    BUDGET="${UNCAPPED_LIMIT:-999999999}"
else
    BUDGET=$(integrity_budget "$DB" "$CYCLE_DAYS" "$MIN_SAMPLE" "$MAX_SAMPLE")
fi

NOW=$(date +%s)
declare -a FLAGGED_PATHS=()
hashed_count=0

# ── Phase 1: progressive discovery ──────────────────────────────────────────────
discovery_complete=$(integrity_meta_get "$DB" "discovery_complete")

if [[ "$discovery_complete" != "true" ]]; then
    tmp_list=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$tmp_list")
    tmp_chunk=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$tmp_chunk")

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

        # A tail|head pipe here would let head close its input early once it
        # has chunk_size lines, SIGPIPEing tail — fatal under `set -o
        # pipefail` on a multi-million-line list. A single sed pass with a
        # `q` at the range end avoids any early-closing consumer.
        _range_end=$(( cursor + chunk_size ))
        sed -n "$((cursor + 1)),${_range_end}{s|^${MOUNTPOINT%/}/||;p};${_range_end}q" \
            "$tmp_list" > "$tmp_chunk"

        candidates_sql=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$candidates_sql")
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
            # Flushed every COMMIT_BATCH_SIZE files rather than accumulated into
            # one transaction for the whole window — on a bounded --uncapped
            # run that window can be tens or hundreds of thousands of files, and
            # without checkpointing a crash near the end would lose the entire
            # run's hashing instead of just the current batch.
            batch_sql=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$batch_sql")
            echo "BEGIN;" > "$batch_sql"
            batch_n=0
            declare -a hash_batch=()

            _flush_hash_batch() {
                [[ ${#hash_batch[@]} -gt 0 ]] || return 0
                local size mtime sum abspath relpath esc_path
                while IFS=$'\t' read -r size mtime sum abspath; do
                    [[ -n "$abspath" ]] || continue
                    relpath="${abspath#"$_MP_PREFIX"}"
                    esc_path="${relpath//\'/\'\'}"
                    echo "INSERT INTO files (path, size, mtime, checksum, status, first_seen, last_updated, last_checked) VALUES ('${esc_path}', ${size}, ${mtime}, '${sum}', 'ok', ${NOW}, ${NOW}, ${NOW});" >> "$batch_sql"
                    (( hashed_count++ )) || true
                    (( batch_n++ )) || true
                    if (( batch_n >= COMMIT_BATCH_SIZE )); then
                        echo "COMMIT;" >> "$batch_sql"
                        sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$batch_sql"
                        echo "BEGIN;" > "$batch_sql"
                        batch_n=0
                    fi
                done < <(integrity_batch_hash "${hash_batch[@]}")
                hash_batch=()
            }

            while IFS= read -r relpath; do
                [[ -n "$relpath" ]] || continue
                abspath="${_MP_PREFIX}${relpath}"
                [[ -f "$abspath" ]] || continue    # vanished between listing and hashing (bash builtin test, no fork)
                hash_batch+=("$abspath")
                if (( ${#hash_batch[@]} >= HASH_BATCH_SIZE )); then
                    _flush_hash_batch
                fi
            done <<< "$new_paths"
            _flush_hash_batch

            if (( batch_n > 0 )); then
                echo "COMMIT;" >> "$batch_sql"
                sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$batch_sql"
            fi
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
    resample_sql=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$resample_sql")
    cat > "$resample_sql" <<SQL
.separator "	"
SELECT id, path, size, mtime, checksum FROM files
WHERE status='ok' AND mtime < ${cutoff}
ORDER BY last_checked ASC LIMIT ${remaining_budget};
SQL
    resample_rows=$(sqlite3 -bail -cmd ".timeout 30000" "$DB" < "$resample_sql")

    if [[ -n "$resample_rows" ]]; then
        batch_sql=$(mktemp -p "$SCRATCH_DIR"); TMPFILES+=("$batch_sql")
        echo "BEGIN;" > "$batch_sql"
        declare -a chunk_ids=() chunk_relpaths=() chunk_rsizes=() chunk_rmtimes=() chunk_rchecksums=() chunk_abspaths=()

        _flush_resample_chunk() {
            [[ ${#chunk_ids[@]} -gt 0 ]] || return 0
            local -A hsize=() hmtime=() hsum=()
            local size mtime sum abspath
            while IFS=$'\t' read -r size mtime sum abspath; do
                [[ -n "$abspath" ]] || continue
                hsize["$abspath"]="$size"; hmtime["$abspath"]="$mtime"; hsum["$abspath"]="$sum"
            done < <(integrity_batch_hash "${chunk_abspaths[@]}")

            local i id relpath rsize rmtime rchecksum abspath esc_path fsize fmtime sum
            for i in "${!chunk_ids[@]}"; do
                id="${chunk_ids[$i]}"; relpath="${chunk_relpaths[$i]}"
                rsize="${chunk_rsizes[$i]}"; rmtime="${chunk_rmtimes[$i]}"; rchecksum="${chunk_rchecksums[$i]}"
                abspath="${chunk_abspaths[$i]}"
                esc_path="${relpath//\'/\'\'}"

                # Vanished/became unreadable between the -f check below and
                # this batch running — leave it for next cycle, same as the
                # fork-per-file code's `|| continue` on a stat/hash failure.
                [[ -n "${hsize[$abspath]+x}" ]] || continue

                fsize="${hsize[$abspath]}"; fmtime="${hmtime[$abspath]}"; sum="${hsum[$abspath]}"

                if [[ "$fsize" != "$rsize" || "$fmtime" != "$rmtime" ]]; then
                    # Legitimate change the reconcile hook should already have
                    # caught — refresh the record silently, no alert.
                    echo "UPDATE files SET size=${fsize}, mtime=${fmtime}, checksum='${sum}', last_updated=${NOW}, last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                elif [[ "$sum" == "$rchecksum" ]]; then
                    echo "UPDATE files SET last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                else
                    echo "UPDATE files SET status='flagged', last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                    echo "INSERT INTO events (ts, path, event_type, detail) VALUES (${NOW}, '${esc_path}', 'mismatch', 'expected ${rchecksum} got ${sum}');" >> "$batch_sql"
                    FLAGGED_PATHS+=("MISMATCH: ${relpath}")
                fi
            done

            chunk_ids=(); chunk_relpaths=(); chunk_rsizes=(); chunk_rmtimes=(); chunk_rchecksums=(); chunk_abspaths=()
        }

        while IFS=$'\t' read -r id relpath rsize rmtime rchecksum; do
            [[ -n "$id" ]] || continue
            abspath="${_MP_PREFIX}${relpath}"

            if [[ ! -f "$abspath" ]]; then
                esc_path="${relpath//\'/\'\'}"
                echo "UPDATE files SET status='flagged', last_checked=${NOW} WHERE id=${id};" >> "$batch_sql"
                echo "INSERT INTO events (ts, path, event_type, detail) VALUES (${NOW}, '${esc_path}', 'missing', 'file no longer present at scheduled check');" >> "$batch_sql"
                FLAGGED_PATHS+=("MISSING: ${relpath}")
                continue
            fi

            chunk_ids+=("$id"); chunk_relpaths+=("$relpath")
            chunk_rsizes+=("$rsize"); chunk_rmtimes+=("$rmtime"); chunk_rchecksums+=("$rchecksum")
            chunk_abspaths+=("$abspath")
            if (( ${#chunk_ids[@]} >= HASH_BATCH_SIZE )); then
                _flush_resample_chunk
            fi
        done <<< "$resample_rows"
        _flush_resample_chunk

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
