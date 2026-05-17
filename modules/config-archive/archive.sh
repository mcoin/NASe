#!/usr/bin/env bash
# modules/config-archive/archive.sh
# Probes config.yaml for changes and copies it to the archive destination.
# Creates a timestamped snapshot on each change; prunes old snapshots.
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

log_section "Config archive"

DEST=$(config_get '.config_archive.dest // "/mnt/primary/NASe"')
RETENTION=$(config_get '.config_archive.retention_days // 90')
ON_FAILURE=$(config_get '.config_archive.on_failure // "notify"')
SOURCE="${REPO_ROOT}/config.yaml"
STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
STAMP_FILE="${STAMP_DIR}/config-archive.stamp"

# Walk up to nearest existing ancestor to check if the destination drive is mounted.
dest_check="$DEST"
while [[ -n "$dest_check" && "$dest_check" != "/" && ! -e "$dest_check" ]]; do
    dest_check="$(dirname "$dest_check")"
done
if ! findmnt --target "$dest_check" --noheadings &>/dev/null; then
    log_info "Destination '${DEST}': drive not mounted — skipping."
    exit 0
fi

mkdir -p "$DEST"

current_hash=$(sha256sum "$SOURCE" | cut -d' ' -f1)
archived_hash=""
[[ -f "${DEST}/config.yaml" ]] && archived_hash=$(sha256sum "${DEST}/config.yaml" | cut -d' ' -f1)

if [[ "$current_hash" != "$archived_hash" ]]; then
    ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
    mkdir -p "${DEST}/${ts}"
    cp "$SOURCE" "${DEST}/${ts}/config.yaml"
    cp "$SOURCE" "${DEST}/config.yaml"
    log_ok "Config archived → ${DEST}/${ts}/"
else
    log_info "Config unchanged since last archive — skipping."
fi

# Prune old snapshots
while IFS= read -r old; do
    rm -rf "$old"
    log_info "Pruned old snapshot: $(basename "$old")"
done < <(find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION" 2>/dev/null)

mkdir -p "$STAMP_DIR"
touch "$STAMP_FILE"
log_ok "Done."
