#!/usr/bin/env bash
# modules/integrity/common.sh — shared helpers for the checksum integrity manifest.
# Source this file; do not execute directly.
# Requires: lib/log.sh already sourced.

INTEGRITY_SCHEMA="${INTEGRITY_SCHEMA:-${REPO_ROOT}/modules/integrity/schema.sql}"

# integrity_db_path MOUNTPOINT
# Path to a drive's manifest DB. Does not check that it exists.
integrity_db_path() {
    echo "${1%/}/.nase/integrity.db"
}

# integrity_relpath MOUNTPOINT ABSPATH
# Strip MOUNTPOINT (and its trailing slash) from ABSPATH — the form paths
# are stored in the files.path column. Callers must ensure ABSPATH is
# actually under MOUNTPOINT.
integrity_relpath() {
    local mp="${1%/}"
    echo "${2#"$mp"/}"
}

# integrity_abspath MOUNTPOINT RELPATH
# Reverse of integrity_relpath.
integrity_abspath() {
    echo "${1%/}/${2}"
}

# _integrity_sql DB SQL
# Run a statement/query against DB with a busy timeout so a concurrent
# writer (another sync job's reconcile, or the nightly sampler) causes a
# short wait instead of "database is locked".
_integrity_sql() {
    local db="$1" sql="$2"
    sqlite3 -bail -cmd ".timeout 30000" "$db" "$sql"
}

# integrity_meta_get DB KEY
# Print the value, or empty string if absent.
integrity_meta_get() {
    local db="$1" key="$2"
    _integrity_sql "$db" "SELECT value FROM meta WHERE key = '${key}';" 2>/dev/null
}

# integrity_meta_set DB KEY VALUE
# VALUE is escaped internally — callers must not pre-escape it.
integrity_meta_set() {
    local db="$1" key="$2" value
    value=$(_integrity_escape "$3")
    _integrity_sql "$db" \
        "INSERT INTO meta (key, value) VALUES ('${key}', '${value}')
         ON CONFLICT(key) DO UPDATE SET value = excluded.value;"
}

# integrity_live_uuid MOUNTPOINT
# The UUID of the block device currently mounted at MOUNTPOINT, or empty.
integrity_live_uuid() {
    findmnt --target "$1" --output UUID --noheadings --first-only 2>/dev/null || true
}

# integrity_check_uuid MOUNTPOINT DB
# Returns 0 if the live UUID at MOUNTPOINT matches meta.drive_uuid recorded
# in DB. Returns 1 (and logs a warning) on any mismatch or if either UUID
# is unavailable — callers should skip writing on failure rather than die,
# consistent with sync.sh's philosophy for expected-but-abnormal conditions
# (see lib/guards.sh). Defense-in-depth against physically swapped/re-cabled
# drives producing cross-contaminated integrity records.
integrity_check_uuid() {
    local mountpoint="$1" db="$2"
    local live recorded
    live=$(integrity_live_uuid "$mountpoint")
    recorded=$(integrity_meta_get "$db" "drive_uuid")
    if [[ -z "$live" || -z "$recorded" || "$live" != "$recorded" ]]; then
        log_warn "Integrity: UUID mismatch at ${mountpoint} (live='${live:-?}', recorded='${recorded:-?}') — skipping write to ${db}."
        return 1
    fi
    return 0
}

# integrity_row_count DB [STATUS]
# Count of rows in files, optionally filtered by status ('ok' or 'flagged').
integrity_row_count() {
    local db="$1" status="${2:-}"
    if [[ -n "$status" ]]; then
        _integrity_sql "$db" "SELECT COUNT(*) FROM files WHERE status = '${status}';" 2>/dev/null || echo 0
    else
        _integrity_sql "$db" "SELECT COUNT(*) FROM files;" 2>/dev/null || echo 0
    fi
}

# integrity_budget DB CYCLE_DAYS MIN_SAMPLE MAX_SAMPLE
# Files to process this run: count(status='ok') / cycle_days, clamped to
# [MIN_SAMPLE, MAX_SAMPLE]. Recomputed from the live row count each call so
# it self-adjusts as the drive's file count grows or shrinks.
integrity_budget() {
    local db="$1" cycle_days="$2" min_sample="$3" max_sample="$4"
    local count budget
    count=$(integrity_row_count "$db" "ok")
    [[ "$cycle_days" -gt 0 ]] || cycle_days=1
    budget=$(( count / cycle_days ))
    (( budget < min_sample )) && budget=$min_sample
    (( budget > max_sample )) && budget=$max_sample
    echo "$budget"
}

# integrity_sha256 FILE
# Print the sha256 as lowercase hex, or empty string if the file could not
# be read (e.g. removed between stat and hash).
integrity_sha256() {
    sha256sum "$1" 2>/dev/null | awk '{print $1}'
}

# integrity_batch_hash ABSPATH...
# Stats and sha256-hashes many files via two subprocess calls total instead
# of two forks per file (both `stat` and `sha256sum` accept any number of
# file operands) — the dominant cost of a large discovery/resample pass is
# forking, not the actual I/O, since rsync (a single compiled process) does
# comparable I/O in a fraction of the time. Emits one
# "size<TAB>mtime<TAB>sha256<TAB>abspath" line per input file that could be
# both stat'd and hashed; a file that vanished or became unreadable between
# being listed and this call is silently omitted (same as the fork-per-file
# code this replaces, which skipped it via `|| continue`). Callers that need
# to distinguish "never existed" from "vanished mid-batch" should check
# `[[ -f "$abspath" ]]` per path first — that's a bash builtin test, not a
# fork, so doing it per-file is free.
integrity_batch_hash() {
    [[ $# -gt 0 ]] || return 0

    local stat_out sum_out
    stat_out=$(stat -c '%s %Y %n' "$@" 2>/dev/null)
    sum_out=$(sha256sum "$@" 2>/dev/null)

    local -A _ibh_size=() _ibh_mtime=()
    local line fsize fmtime rest
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        read -r fsize fmtime rest <<< "$line"
        _ibh_size["$rest"]="$fsize"
        _ibh_mtime["$rest"]="$fmtime"
    done <<< "$stat_out"

    local sum path
    while IFS= read -r line; do
        [[ -n "$line" ]] || continue
        # GNU sha256sum's output is "<64-hex-hash>  <path>" (two spaces) —
        # slicing by fixed width instead of word-splitting keeps this safe
        # for paths containing spaces.
        sum="${line:0:64}"
        path="${line:66}"
        [[ -n "${_ibh_size[$path]+x}" ]] || continue
        printf '%s\t%s\t%s\t%s\n' "${_ibh_size[$path]}" "${_ibh_mtime[$path]}" "$sum" "$path"
    done <<< "$sum_out"
}

# integrity_log_event DB EVENT_TYPE PATH [DETAIL]
integrity_log_event() {
    local db="$1" event_type="$2" path="$3" detail="${4:-}"
    local now
    now=$(date +%s)
    _integrity_sql "$db" \
        "INSERT INTO events (ts, path, event_type, detail)
         VALUES (${now}, '$(_integrity_escape "$path")', '${event_type}', '$(_integrity_escape "$detail")');"
}

# _integrity_escape STRING
# Escape single quotes for embedding in a SQL literal. Paths/details are the
# only untrusted-ish input reaching these queries (filenames on the drive);
# everything else here is fixed SQL built by this module's own scripts.
_integrity_escape() {
    printf '%s' "${1//\'/\'\'}"
}

# integrity_status_cache_path MOUNTPOINT
# SD-card path for a drive's cached status snapshot — see
# integrity_write_status_cache. Slug matches the lock/date-stamp naming
# already used elsewhere in this module (leading "/" stripped, "/" -> "-").
integrity_status_cache_path() {
    local slug="${1#/}"
    slug="${slug//\//-}"
    echo "${NASE_STAMP_DIR:-/var/lib/nase}/integrity-status/${slug}.json"
}

# integrity_write_status_cache MOUNTPOINT DB
# Snapshots exactly what the web dashboard's /integrity page needs (counts,
# discovery progress, flagged files) to a JSON file on the SD card, so that
# page never has to open the manifest on the drive itself — which, on an
# HTMX page that polls every 60s, would otherwise keep re-waking (or simply
# keep from ever spinning down) any drive with the page left open in a
# browser tab, not just wake it once on load.
#
# Call this right after any write to DB — the drive is already awake for
# that write, so this adds no extra spin-up of its own. The dashboard shows
# whatever was last written here (see "updated_at"), so it lags reality by
# however long it's been since the drive last actually ran an integrity
# pass — that's the deliberate trade for never waking the drive just to look.
integrity_write_status_cache() {
    local mountpoint="$1" db="$2"
    local cache_dir cache_file tmp
    cache_dir="${NASE_STAMP_DIR:-/var/lib/nase}/integrity-status"
    mkdir -p "$cache_dir"
    cache_file=$(integrity_status_cache_path "$mountpoint")
    tmp=$(mktemp -p "$cache_dir")
    if ! sqlite3 -bail -cmd ".timeout 30000" "$db" <<'SQL' > "$tmp"
WITH counts AS (
  SELECT
    (SELECT COUNT(*) FROM files WHERE status='ok')      AS ok_n,
    (SELECT COUNT(*) FROM files WHERE status='flagged') AS flagged_n
),
flagged AS (
  SELECT f.path, f.last_checked, e.event_type, e.detail
  FROM files f
  LEFT JOIN events e ON e.id = (
    SELECT id FROM events e2
    WHERE e2.path = f.path AND e2.event_type IN ('mismatch', 'missing')
    ORDER BY e2.ts DESC LIMIT 1
  )
  WHERE f.status = 'flagged'
  ORDER BY f.last_checked DESC
  LIMIT 200
)
SELECT json_object(
  'has_manifest',       json('true'),
  'total',               (SELECT ok_n + flagged_n FROM counts),
  'ok',                  (SELECT ok_n FROM counts),
  'flagged',             (SELECT flagged_n FROM counts),
  'discovery_complete',  json(CASE WHEN (SELECT value FROM meta WHERE key='discovery_complete') = 'true'
                                THEN 'true' ELSE 'false' END),
  'discovery_total',     (SELECT value FROM meta WHERE key='discovery_total'),
  'flagged_truncated',   json(CASE WHEN (SELECT flagged_n FROM counts) > (SELECT COUNT(*) FROM flagged)
                                THEN 'true' ELSE 'false' END),
  'updated_at',          CAST(strftime('%s','now') AS INTEGER),
  'flagged_rows',        (SELECT json_group_array(json_object(
                             'path', path, 'last_checked', last_checked,
                             'event_type', COALESCE(event_type, 'unknown'),
                             'detail', COALESCE(detail, '')
                           )) FROM flagged)
);
SQL
    then
        rm -f "$tmp"
        log_warn "Integrity: failed to write status cache for ${mountpoint} — dashboard will show stale/no data."
        return 1
    fi
    mv "$tmp" "$cache_file"
    chmod 644 "$cache_file"
}
