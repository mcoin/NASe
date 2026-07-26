#!/usr/bin/env bash
# modules/config-archive/archive.sh
# Probes config.yaml for changes and copies it to the archive destination.
# Creates a timestamped snapshot on each change; prunes old snapshots.
#
# The change check is done against a hash cached on the SD card, not by
# re-reading the archived copy on the destination drive: on a no-op night
# (the common case) this must not touch the destination at all, or a job
# that runs daily would spin up an otherwise-idle drive for nothing.
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
HASH_FILE="${STAMP_DIR}/config-archive-hash.stamp"

current_hash=$(sha256sum "$SOURCE" | cut -d' ' -f1)
last_hash=""
[[ -f "$HASH_FILE" ]] && last_hash=$(<"$HASH_FILE")

if [[ "$current_hash" == "$last_hash" ]]; then
    log_info "Config unchanged since last archive — skipping (no drive access)."
    exit 0
fi

# Only touch the destination now that we know there's actually something to
# archive. Walk up to nearest existing ancestor to check it's mounted.
dest_check="$DEST"
while [[ -n "$dest_check" && "$dest_check" != "/" && ! -e "$dest_check" ]]; do
    dest_check="$(dirname "$dest_check")"
done
if ! findmnt --target "$dest_check" --noheadings &>/dev/null; then
    log_info "Destination '${DEST}': drive not mounted — skipping."
    exit 0
fi

mkdir -p "$DEST"
ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
mkdir -p "${DEST}/${ts}"
cp "$SOURCE" "${DEST}/${ts}/config.yaml"
cp "$SOURCE" "${DEST}/config.yaml"
log_ok "Config archived → ${DEST}/${ts}/"

mkdir -p "$STAMP_DIR"
echo "$current_hash" > "$HASH_FILE"

# Prune old snapshots — only reached when the drive is already awake above.
while IFS= read -r old; do
    rm -rf "$old"
    log_info "Pruned old snapshot: $(basename "$old")"
done < <(find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION" 2>/dev/null)

touch "$STAMP_FILE"
log_ok "Done."
