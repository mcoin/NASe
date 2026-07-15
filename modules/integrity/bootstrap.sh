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
# Usage: bootstrap.sh <mountpoint> [limit]
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

MOUNTPOINT="${1:-}"
LIMIT="${2:-}"
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: bootstrap.sh <mountpoint> [limit]"; exit 1; }

log_section "Integrity bootstrap: ${MOUNTPOINT}"
if [[ -n "$LIMIT" ]]; then
    log_warn "This hashes up to ${LIMIT} undiscovered file(s) on ${MOUNTPOINT} at full speed, then stops."
    log_warn "Safe to re-run (e.g. once a day) — it resumes where it left off until discovery completes."
    exec "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$MOUNTPOINT" --uncapped "$LIMIT"
else
    log_warn "This hashes every undiscovered file on ${MOUNTPOINT} in one uncapped pass."
    log_warn "On a multi-terabyte drive this can take many hours and will keep the drive spinning throughout."
    log_warn "Pass a limit (e.g. 'nase integrity bootstrap ${MOUNTPOINT##*/} 200000') to spread this over several runs instead."
    exec "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$MOUNTPOINT" --uncapped
fi
