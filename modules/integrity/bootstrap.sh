#!/usr/bin/env bash
# modules/integrity/bootstrap.sh
# Manual, full-speed discovery pass for one drive — the same discovery logic
# as the nightly budgeted job, just with no cap. Not required for the
# checksum manifest to eventually cover every file (that happens
# progressively on its own, see INTEGRITY_DESIGN.md), but useful right after
# physically swapping in a new drive when you'd rather have full coverage
# now than wait out the normal ramp-up.
# Usage: bootstrap.sh <mountpoint>
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"

MOUNTPOINT="${1:-}"
[[ -n "$MOUNTPOINT" ]] || { log_error "Usage: bootstrap.sh <mountpoint>"; exit 1; }

log_section "Integrity bootstrap: ${MOUNTPOINT}"
log_warn "This hashes every undiscovered file on ${MOUNTPOINT} in one uncapped pass."
log_warn "On a multi-terabyte drive this can take hours and will keep the drive spinning throughout."

exec "${REPO_ROOT}/modules/integrity/discover_and_sample.sh" "$MOUNTPOINT" --uncapped
