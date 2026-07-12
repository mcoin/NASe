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
