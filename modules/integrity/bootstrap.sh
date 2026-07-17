#!/usr/bin/env bash
# modules/integrity/bootstrap.sh
# Manual, full-speed discovery pass for one drive — the same discovery logic
# as the nightly budgeted job, just with no per-night cap. Not required for
# the checksum manifest to eventually cover every file (that happens
# progressively on its own, see INTEGRITY_DESIGN.md), but useful right after
# physically swapping in a new drive when you'd rather have full coverage
# now than wait out the normal ramp-up.
#
# An optional LIMIT caps this invocation to that many newly-hashed files
# instead of draining the entire remaining backlog. Progress is committed
# incrementally (in batches, not one all-or-nothing transaction) and the
# discovery cursor persists across runs, so re-running with a limit — once a
# day, say — safely spreads a multi-million-file backlog over several days
# instead of one long, all-or-nothing pass.
#
# With no LIMIT, this runs the same capped logic as a sequence of
# CHUNK_SIZE-file passes back to back until discovery completes, rather than
# one all-or-nothing uncapped pass. An uncapped pass with no limit collapses
# discover_and_sample.sh's chunk_size to the entire remaining backlog (see
# its BUDGET*4 sizing), which on a multi-million-file drive means the
# candidate-list-building step alone churns through millions of files —
# in a bash while-loop, one fork per line — before any hashing even starts.
# That, plus a multi-hour single writer transaction contending with the web
# dashboard's read polling, is what caused a real "cannot commit - no
# transaction is active" crash in production. Chaining capped passes keeps
# every pass's cost (and lock hold time) the same as a manual limited run.
#
# Usage: bootstrap.sh <mountpoint> [limit]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/modules/integrity/common.sh"

MOUNTPOINT="${1:-}"
LIMIT="${2:-}"
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: bootstrap.sh <mountpoint> [limit]"; exit 1; }

log_section "Integrity bootstrap: ${MOUNTPOINT}"

if ! config_bool '.integrity.enabled' 2>/dev/null; then
    log_info "Checksum integrity manifest disabled (integrity.enabled != true) — skipping."
    exit 0
fi

if [[ -n "$LIMIT" ]]; then
    log_warn "This hashes up to ${LIMIT} undiscovered file(s) on ${MOUNTPOINT} at full speed, then stops."
    log_warn "Safe to re-run (e.g. once a day) — it resumes where it left off until discovery completes."
    exec "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$MOUNTPOINT" --uncapped "$LIMIT"
fi

# Fixed pass size for the no-limit case — matches the size that's already
# been proven not to trigger the candidate-list/lock-contention problems
# described above. Not config-driven, same rationale as
# discover_and_sample.sh's COMMIT_BATCH_SIZE.
CHUNK_SIZE=200000
log_warn "This hashes every undiscovered file on ${MOUNTPOINT}, in passes of ${CHUNK_SIZE} file(s) each, until discovery is complete."
log_warn "Each pass takes its own lock and commits its own progress, so it interleaves with nightly syncs and the web dashboard like a manual capped run would."

DB=$(integrity_db_path "$MOUNTPOINT")
[[ -f "$DB" ]] || { log_info "Integrity: no manifest at ${DB} — skipping (run apply.sh first)."; exit 0; }

while true; do
    cursor_before=$(integrity_meta_get "$DB" "discovery_cursor_n"); cursor_before="${cursor_before:-0}"

    "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$MOUNTPOINT" --uncapped "$CHUNK_SIZE"

    discovery_complete=$(integrity_meta_get "$DB" "discovery_complete")
    [[ "$discovery_complete" == "true" ]] && break

    # Guard against spinning forever with no error and no progress — e.g. a
    # UUID mismatch (integrity_check_uuid) or the drive going unmounted mid-
    # bootstrap both make discover_and_sample.sh a silent no-op (exit 0)
    # every pass, which would otherwise loop here indefinitely.
    cursor_after=$(integrity_meta_get "$DB" "discovery_cursor_n"); cursor_after="${cursor_after:-0}"
    if [[ "$cursor_after" == "$cursor_before" ]]; then
        log_error "Integrity: ${MOUNTPOINT} made no discovery progress this pass — stopping instead of looping forever."
        log_error "Check 'sudo nase integrity status ${MOUNTPOINT##*/}' and the drive's mount/UUID state."
        exit 1
    fi
done

log_ok "Integrity bootstrap: ${MOUNTPOINT} discovery complete."
