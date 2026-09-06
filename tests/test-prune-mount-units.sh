#!/usr/bin/env bash
# tests/test-prune-mount-units.sh — modules/drives/prune_mount_units.sh
# (backlog #31).
#
# The first cut of this logic aborted the entire drives module the moment it
# met a bind-mount unit: `grep -oE by-uuid/...` finds nothing there, and under
# `set -o pipefail` that failure propagates out of the assignment. apply.sh
# exited 1 half-way through configuring the drives. Hence the deliberately
# mixed fixture below — managed drive units, a managed bind-mount unit with no
# UUID, and a foreign unit — run in one pass.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

WORK=$(mktemp -d /tmp/nase-test-prune.XXXXXX)
STUBS="${WORK}/stubs"
UNITS="${WORK}/units"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STUBS" "$UNITS"

export NAS_LOG="${WORK}/nase.log"
export CALLS="${WORK}/calls.txt"
: > "$CALLS"

cat > "${STUBS}/systemctl" <<'STUB'
#!/usr/bin/env bash
echo "systemctl $*" >> "$CALLS"
exit 0
STUB
# Nothing in the fixture is really mounted.
cat > "${STUBS}/findmnt" <<'STUB'
#!/usr/bin/env bash
exit 1
STUB
chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"

cat > "${WORK}/config.yaml" <<'YAML'
drives:
  - name: primary
    active: true
    uuid: "aaaa-1111"
    mountpoint: /mnt/primary
  - name: backup_parked
    active: false
    uuid: "bbbb-2222"
    mountpoint: /mnt/backup_parked
YAML
export CONFIG_FILE="${WORK}/config.yaml"
export NASE_SYSTEMD_DIR="$UNITS"

write_unit() {  # write_unit <name> <uuid|-> <where> <managed:yes|no>
    local file="${UNITS}/$1" uuid="$2" where="$3" managed="$4"
    {
        [[ "$managed" == "yes" ]] && echo "# Managed by NASe — do not edit manually."
        echo "[Mount]"
        [[ "$uuid" != "-" ]] && echo "What=/dev/disk/by-uuid/${uuid}"
        echo "Where=${where}"
    } > "$file"
}

GONE_MP="${WORK}/mnt/backup_weekly"
mkdir -p "$GONE_MP"
NONEMPTY_MP="${WORK}/mnt/backup_old"
mkdir -p "${NONEMPTY_MP}/leftover"

write_unit "mnt-primary.mount"        "aaaa-1111" "/mnt/primary"        yes
write_unit "mnt-backup_parked.mount"  "bbbb-2222" "/mnt/backup_parked"  yes
write_unit "mnt-backup_weekly.mount"  "cccc-3333" "$GONE_MP"            yes
write_unit "mnt-backup_old.mount"     "dddd-4444" "$NONEMPTY_MP"        yes
write_unit "srv-filebrowser-movies.mount" "-"     "/srv/filebrowser/movies" yes
write_unit "mnt-someone-elses.mount"  "eeee-5555" "/mnt/foreign"        no

echo "=== modules/drives/prune_mount_units.sh ==="
echo ""

assert_exit0 "a mixed unit directory does not abort the run" \
    bash "${REPO_ROOT}/modules/drives/prune_mount_units.sh"

assert_file_absent "a drive no longer in config.yaml loses its unit" \
    "${UNITS}/mnt-backup_weekly.mount"
assert_dir_absent "and its empty mountpoint goes with it" "$GONE_MP"

assert_file_exists "a configured drive keeps its unit" "${UNITS}/mnt-primary.mount"
assert_file_exists "an inactive-but-configured drive keeps its unit" \
    "${UNITS}/mnt-backup_parked.mount"
assert_file_exists "a bind-mount unit with no UUID is left to its own module" \
    "${UNITS}/srv-filebrowser-movies.mount"
assert_file_exists "a unit NASe did not write is never touched" \
    "${UNITS}/mnt-someone-elses.mount"

assert_file_absent "an obsolete unit is removed even when its mountpoint is not empty" \
    "${UNITS}/mnt-backup_old.mount"
assert_exit0 "but the non-empty directory is left for a human to look at" \
    test -d "${NONEMPTY_MP}/leftover"

calls=$(cat "$CALLS")
assert_contains "the removed unit is disabled first" \
    "systemctl disable --now mnt-backup_weekly.mount" "$calls"
assert_contains "and systemd is reloaded once units changed" \
    "systemctl daemon-reload" "$calls"

# Second pass: nothing left to remove, and no reload for a no-op run.
: > "$CALLS"
assert_exit0 "re-running is a no-op" \
    bash "${REPO_ROOT}/modules/drives/prune_mount_units.sh"
assert_not_contains "with no needless daemon-reload" "daemon-reload" "$(cat "$CALLS")"

test_summary
