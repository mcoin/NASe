#!/usr/bin/env bash
# tests/test-teardown.sh — modules/drives/teardown.sh, the ordered shutdown
# teardown (backlog #31).
#
# What matters here is order and tolerance: bind mounts have to come off
# before the drives they sit on, a drive left read-write has to be flushed,
# and nothing may be allowed to fail the script — a teardown that aborts
# halfway leaves exactly the half-dismantled state that hangs a shutdown.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

WORK=$(mktemp -d /tmp/nase-test-teardown.XXXXXX)
STUBS="${WORK}/stubs"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STUBS"

export NAS_LOG="${WORK}/nase.log"
export CALLS="${WORK}/calls.txt"

# findmnt stub: MOUNTS is "<target>|<options>" per line, in mount order.
cat > "${STUBS}/findmnt" <<'STUB'
#!/usr/bin/env bash
args="$*"
case "$args" in
    *"-no OPTIONS --target "*)
        target="${args##* }"
        while IFS='|' read -r t o; do
            [[ "$t" == "$target" ]] && { echo "$o"; exit 0; }
        done <<< "$MOUNTS"
        exit 1 ;;
    *"-rno TARGET"*)
        while IFS='|' read -r t o; do [[ -n "$t" ]] && echo "$t"; done <<< "$MOUNTS"
        exit 0 ;;
    *"-no TARGET "*)
        target="${args##* }"
        while IFS='|' read -r t o; do
            [[ "$t" == "$target" ]] && { echo "$t"; exit 0; }
        done <<< "$MOUNTS"
        exit 1 ;;
esac
exit 1
STUB

# umount stub: records calls; refuses any path listed in BUSY_PATHS unless -l.
cat > "${STUBS}/umount" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "-l" ]]; then
    echo "umount-lazy $2" >> "$CALLS"
    exit 0
fi
echo "umount $1" >> "$CALLS"
for b in ${BUSY_PATHS:-}; do
    [[ "$1" == "$b" ]] && exit 1
done
exit 0
STUB

cat > "${STUBS}/mount" <<'STUB'
#!/usr/bin/env bash
echo "mount $*" >> "$CALLS"
exit 0
STUB

cat > "${STUBS}/sync" <<'STUB'
#!/usr/bin/env bash
echo "sync" >> "$CALLS"
exit 0
STUB

chmod +x "${STUBS}"/*
export PATH="${STUBS}:${PATH}"

cat > "${WORK}/config.yaml" <<'YAML'
drives:
  - name: primary
    active: true
    uuid: "aaaa-1111"
    mountpoint: /mnt/primary
  - name: backup_daily
    active: true
    uuid: "bbbb-2222"
    mountpoint: /mnt/backup_daily
  - name: backup_gone
    active: false
    uuid: "cccc-3333"
    mountpoint: /mnt/backup_gone
YAML
export CONFIG_FILE="${WORK}/config.yaml"

run_teardown() {
    : > "$CALLS"
    REPO_ROOT="$REPO_ROOT" CONFIG_FILE="$CONFIG_FILE" \
        bash "${REPO_ROOT}/modules/drives/teardown.sh" &>/dev/null
}

echo "=== modules/drives/teardown.sh ==="
echo ""

# A realistic tree: two bind mounts on the drives, one nested inside the other.
export MOUNTS="/mnt/primary|rw,noatime
/mnt/backup_daily|ro,noatime
/srv/filebrowser/movies|rw,noatime
/srv/filebrowser/movies/hd|rw,noatime"

run_teardown
calls=$(cat "$CALLS")

assert_contains "a read-write drive is remounted ro to flush it" \
    "mount -o remount,ro /mnt/primary" "$calls"
assert_not_contains "a drive already ro is left alone" \
    "remount,ro /mnt/backup_daily" "$calls"
assert_contains "bind mounts are unmounted" "umount /srv/filebrowser/movies" "$calls"
assert_contains "drive mounts are unmounted" "umount /mnt/primary" "$calls"
assert_contains "buffers are flushed at the end" "sync" "$calls"

nested_line=$(grep -n "umount /srv/filebrowser/movies/hd" "$CALLS" | cut -d: -f1)
parent_line=$(grep -n "umount /srv/filebrowser/movies$" "$CALLS" | cut -d: -f1)
drive_line=$(grep -n "umount /mnt/primary" "$CALLS" | cut -d: -f1)
assert_exit0 "the nested bind mount comes off before its parent" \
    test "$nested_line" -lt "$parent_line"
assert_exit0 "bind mounts come off before the drive underneath" \
    test "$parent_line" -lt "$drive_line"
assert_exit0 "the flush happens after the unmounts" \
    test "$drive_line" -lt "$(grep -n '^sync$' "$CALLS" | cut -d: -f1)"

# An inactive drive is one NASe is deliberately running without.
assert_not_contains "an inactive drive is not touched" "/mnt/backup_gone" "$calls"

# A mount nobody can release must not stop the teardown: the lazy detach is
# the whole reason a busy bind mount cannot wedge a shutdown here.
export BUSY_PATHS="/srv/filebrowser/movies"
run_teardown
calls=$(cat "$CALLS")
assert_contains "a busy mount falls back to a lazy unmount" \
    "umount-lazy /srv/filebrowser/movies" "$calls"
assert_contains "and the teardown carries on to the drives" \
    "umount /mnt/primary" "$calls"

# Nothing mounted at all — a shutdown after a failed boot, say.
export MOUNTS=""
export BUSY_PATHS=""
assert_exit0 "an empty mount table is not an error" run_teardown

test_summary
