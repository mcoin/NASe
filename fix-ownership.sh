#!/usr/bin/env bash
# fix-ownership.sh
# Recursively sets ownership of all files on drives that have an 'owner'
# field in config.yaml.
#
# This can take a very long time on large drives (potentially hours for
# several TB). Run it once after migrating data from another system.
# It does not need to be run again unless you add new drives or change owners.
#
# Usage: sudo ./fix-ownership.sh
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export REPO_ROOT

source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/checks.sh"

check_root

n=$(config_len '.drives')
targets=()

for i in $(seq 0 $((n - 1))); do
    name=$(config_idx '.drives' "$i" '.name')
    active=$(config_idx '.drives' "$i" '.active')
    owner=$(config_idx '.drives' "$i" '.owner')
    mountpoint=$(config_idx '.drives' "$i" '.mountpoint')

    [[ "$active" != "false" ]] || continue
    [[ -n "$owner" ]] || continue

    if [[ ! -d "$mountpoint" ]]; then
        log_warn "Drive '${name}': mountpoint '${mountpoint}' not found — skipping."
        continue
    fi

    targets+=("${name}|${mountpoint}|${owner}")
done

if [[ ${#targets[@]} -eq 0 ]]; then
    log_info "No drives with an 'owner' field found in config.yaml — nothing to do."
    exit 0
fi

log_warn "This will recursively change ownership of all files on the following drives:"
for t in "${targets[@]}"; do
    IFS='|' read -r name mountpoint owner <<< "$t"
    log_warn "  ${mountpoint} → ${owner}:${owner}  (drive: ${name})"
done
log_warn "This may take a very long time on large drives."
echo ""
read -r -p "Continue? [y/N] " confirm
[[ "${confirm,,}" == "y" ]] || { log_info "Aborted."; exit 0; }

for t in "${targets[@]}"; do
    IFS='|' read -r name mountpoint owner <<< "$t"
    log_info "Fixing ownership on '${name}' (${mountpoint}) → ${owner}:${owner} ..."
    chown -R "${owner}:${owner}" "$mountpoint"
    log_ok "Done: ${mountpoint}"
done

log_ok "Ownership fixed on all drives."
