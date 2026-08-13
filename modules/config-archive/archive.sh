#!/usr/bin/env bash
# modules/config-archive/archive.sh
# Archives NASe's own small state files to a drive: config.yaml and the
# backlog. Creates a timestamped snapshot when something has changed; prunes
# old snapshots.
#
# Two rules shape this script, and both exist to keep the drives asleep:
#
#   1. Change detection reads hashes cached on the SD card, never the copies
#      on the destination drive. On a no-op night (the common case) the
#      destination is not touched at all.
#   2. A change does not by itself justify spinning a drive up. config.yaml
#      changes rarely, but the backlog changes most days, so writing on every
#      change would wake the primary drive nearly every night — undoing the
#      pooling set up in backlog #3 and #4. Pending changes are therefore held
#      on the SD card and flushed on a pinned day (config_archive.flush_calendar),
#      or as soon as the drive is found awake for another reason, whichever
#      comes first. flush_max_age_days is the backstop so "pinned day missed"
#      can never become "never archived".
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"
source "${REPO_ROOT}/lib/calendar.sh"

log_section "Config archive"

DEST=$(config_get '.config_archive.dest // "/mnt/primary/NASe"')
RETENTION=$(config_get '.config_archive.retention_days // 90')
FLUSH_CALENDAR=$(config_get '.config_archive.flush_calendar // ""')
FLUSH_MAX_AGE=$(config_get '.config_archive.flush_max_age_days // 10')
STAMP_DIR="${NASE_STAMP_DIR:-/var/lib/nase}"
STAMP_FILE="${STAMP_DIR}/config-archive.stamp"
PENDING_FILE="${STAMP_DIR}/config-archive-pending.stamp"

# The state files worth keeping off this SD card, as "<archived-name>=<path>".
# Deliberately a fixed list rather than config: this is NASe's own state, not
# a user setting, and a mistyped path here would silently archive nothing.
SOURCES=(
    "config.yaml=${REPO_ROOT}/config.yaml"
    "backlog.json=${NASE_BACKLOG_FILE:-${STAMP_DIR}/backlog.json}"
    "backlog-attachments=${NASE_ATTACHMENT_DIR:-${STAMP_DIR}/backlog-attachments}"
)

# ── Which sources changed since the last archive? ────────────────────────────
# Hashes live on the SD card, one stamp per source, so this costs no drive
# access whatsoever.
changed_names=()
declare -A source_path_of source_hash_of

# hash_source <path> — one hash covering a file, or a directory's whole content.
# Directory hashing walks names and bytes so a renamed or deleted screenshot is
# a change too, not just an edited one.
hash_source() {
    local path="$1"
    if [[ -d "$path" ]]; then
        find "$path" -type f -print0 2>/dev/null | sort -z \
            | xargs -0 -r sha256sum 2>/dev/null | sha256sum | cut -d' ' -f1
    else
        sha256sum "$path" | cut -d' ' -f1
    fi
}

for entry in "${SOURCES[@]}"; do
    name="${entry%%=*}"
    path="${entry#*=}"
    [[ -e "$path" ]] || continue

    # A truncated file must never be promoted over a good snapshot. JSON is
    # the case that matters (the web app rewrites the backlog under a person's
    # fingers); a torn YAML would fail the same way.
    case "$name" in
        *.json) python3 -c 'import json,sys; json.load(open(sys.argv[1]))' "$path" 2>/dev/null \
                    || { log_warn "Source '${name}' is not valid JSON right now — skipping it this run."; continue; } ;;
    esac

    hash=$(hash_source "$path")
    hash_file="${STAMP_DIR}/config-archive-hash-${name}.stamp"
    # Migration: the old single-file stamp only ever covered config.yaml.
    if [[ "$name" == "config.yaml" && ! -f "$hash_file" && -f "${STAMP_DIR}/config-archive-hash.stamp" ]]; then
        mv "${STAMP_DIR}/config-archive-hash.stamp" "$hash_file"
    fi
    last_hash=""
    [[ -f "$hash_file" ]] && last_hash=$(<"$hash_file")

    source_path_of["$name"]="$path"
    source_hash_of["$name"]="$hash"
    [[ "$hash" == "$last_hash" ]] || changed_names+=("$name")
done

if [[ ${#changed_names[@]} -eq 0 ]]; then
    rm -f "$PENDING_FILE"
    log_info "No state files changed since last archive — skipping (no drive access)."
    exit 0
fi

log_info "Changed since last archive: ${changed_names[*]}"

# ── Should the change be flushed to the drive now? ───────────────────────────
mkdir -p "$STAMP_DIR"
[[ -f "$PENDING_FILE" ]] || date +%s > "$PENDING_FILE"
pending_since=$(<"$PENDING_FILE")
pending_days=$(( ( $(date +%s) - pending_since ) / 86400 ))
[[ $pending_days -lt 0 ]] && pending_days=0

flush=false
reason=""

if [[ -z "$FLUSH_CALENDAR" ]]; then
    # No pin configured: behave as this script always has, writing on change.
    flush=true
    reason="no flush_calendar configured"
elif ! calendar_spec_valid "$FLUSH_CALENDAR"; then
    # Same reasoning as sync.sh: a typo must not silently stop archiving.
    log_warn "config_archive.flush_calendar '${FLUSH_CALENDAR}' is not a valid systemd calendar expression — archiving now instead of waiting for it."
    flush=true
    reason="invalid flush_calendar"
elif calendar_matches_day "$FLUSH_CALENDAR"; then
    flush=true
    reason="today matches flush_calendar '${FLUSH_CALENDAR}'"
elif [[ "$FLUSH_MAX_AGE" -gt 0 && "$pending_days" -ge "$FLUSH_MAX_AGE" ]]; then
    flush=true
    reason="pending for ${pending_days}d (max ${FLUSH_MAX_AGE}d)"
else
    # Free ride: if something else already woke the drive, use it.
    dest_drive=""
    n=$(config_len '.drives')
    for i in $(seq 0 $((n - 1))); do
        mp=$(config_idx '.drives' "$i" '.mountpoint')
        [[ -n "$mp" && "$DEST" == "$mp"* ]] || continue
        dest_drive=$(config_idx '.drives' "$i" '.name')
        break
    done
    if [[ -n "$dest_drive" ]]; then
        # spin_status.sh never wakes a drive to answer. It can legitimately
        # fail (drive absent, state dir unwritable); "cannot tell" must mean
        # "hold the change", never "abort the archive".
        spin_state=$("${REPO_ROOT}/modules/drives/spin_status.sh" "$dest_drive" 2>/dev/null \
                     | awk '{print $1}' || true)
        if [[ "$spin_state" == "active" ]]; then
            flush=true
            reason="drive '${dest_drive}' is already awake"
        fi
    fi
fi

if [[ "$flush" != "true" ]]; then
    log_info "Holding ${#changed_names[@]} changed file(s) on the SD card (pending ${pending_days}d): waiting for flush_calendar '${FLUSH_CALENDAR}', the drive to be awake, or ${FLUSH_MAX_AGE}d."
    exit 0
fi

log_info "Flushing to '${DEST}': ${reason}."

# ── Only now does anything touch the destination drive ───────────────────────
dest_check="$DEST"
while [[ -n "$dest_check" && "$dest_check" != "/" && ! -e "$dest_check" ]]; do
    dest_check="$(dirname "$dest_check")"
done
if ! findmnt --target "$dest_check" --noheadings &>/dev/null; then
    log_info "Destination '${DEST}': drive not mounted — skipping (change stays pending)."
    exit 0
fi

mkdir -p "$DEST"
# Snapshot names have second resolution, so two archives in the same second
# would otherwise land in one directory and quietly overwrite each other's
# history. Rare in normal operation (this runs daily), but a snapshot that
# silently replaces another is the wrong failure for a backup to have.
ts=$(date -u +%Y-%m-%dT%H-%M-%SZ)
snap="${DEST}/${ts}"
seq_n=1
while [[ -e "$snap" ]]; do
    seq_n=$(( seq_n + 1 ))
    snap="${DEST}/${ts}-${seq_n}"
done
mkdir -p "$snap"
for name in "${!source_path_of[@]}"; do
    src="${source_path_of[$name]}"
    if [[ -d "$src" ]]; then
        # -T so the copy lands as <dest>/<name>, not nested inside an existing
        # directory of that name on the second run.
        cp -aT "$src" "${snap}/${name}"
        rm -rf "${DEST:?}/${name}"
        cp -aT "$src" "${DEST}/${name}"
    else
        cp "$src" "${snap}/${name}"
        cp "$src" "${DEST}/${name}"
    fi
done
log_ok "Archived ${#source_path_of[@]} file(s) → ${snap}/"

for name in "${!source_hash_of[@]}"; do
    echo "${source_hash_of[$name]}" > "${STAMP_DIR}/config-archive-hash-${name}.stamp"
done
rm -f "$PENDING_FILE"

# Prune old snapshots — only reached when the drive is already awake above.
while IFS= read -r old; do
    rm -rf "$old"
    log_info "Pruned old snapshot: $(basename "$old")"
done < <(find "$DEST" -maxdepth 1 -mindepth 1 -type d -mtime +"$RETENTION" 2>/dev/null)

touch "$STAMP_FILE"
log_ok "Done."
