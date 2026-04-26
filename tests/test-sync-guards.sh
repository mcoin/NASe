#!/usr/bin/env bash
# tests/test-sync-guards.sh — tests for the mount safety guards in lib/guards.sh.
#
# These tests mock findmnt to simulate drive-mounted and drive-unmounted
# scenarios without needing real block devices or root access.
# No root needed; no drives needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/log.sh"

echo "=== lib/guards.sh ==="
echo ""

ROOT_DEV="/dev/mmcblk0p2"  # representative root device

# ── Helper: run is_safe_mount_path with a mocked findmnt ─────────────────────
# We override findmnt as a shell function for the duration of each test.

run_guard() {
    local mock_output="$1"  # what findmnt returns for the tested path
    local path="$2"
    local label="test-label"

    # Define mock findmnt that returns mock_output for any call
    findmnt() { echo "$mock_output"; }

    # Source guards in this subshell so they pick up the mocked findmnt
    source "${REPO_ROOT}/lib/guards.sh"

    is_safe_mount_path "$label" "$path" "$ROOT_DEV"
}
export -f run_guard

# is_safe_mount_path returns 0 (safe) or 1 (unsafe/skip).
# We call it in a subshell so the mock findmnt doesn't leak.

# ── Normal mounted drive (returns a non-root device) ─────────────────────────
assert_exit0 "safe: source on its own device" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { echo '/dev/sda1'; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Source' '/mnt/primary' '${ROOT_DEV}'
    "

# ── Source drive is the root device (e.g. /mnt/primary IS on SD card) ────────
assert_exit1 "unsafe: source resolves to root device" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { echo '${ROOT_DEV}'; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Source' '/mnt/primary' '${ROOT_DEV}'
    "

# ── findmnt returns empty (drive unmounted, directory exists on SD card) ──────
assert_exit1 "unsafe: findmnt returns empty (unmounted drive)" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { echo ''; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Source' '/mnt/primary' '${ROOT_DEV}'
    "

# ── findmnt fails entirely (returns non-zero) ────────────────────────────────
assert_exit1 "unsafe: findmnt fails (treated as unmounted)" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { return 1; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Source' '/mnt/primary' '${ROOT_DEV}'
    "

# ── Destination on its own device ────────────────────────────────────────────
assert_exit0 "safe: destination on its own device" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { echo '/dev/sdb1'; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Destination' '/mnt/backup' '${ROOT_DEV}'
    "

# ── Destination resolves to root device ──────────────────────────────────────
assert_exit1 "unsafe: destination resolves to root device" \
    bash -c "
        source '${REPO_ROOT}/lib/log.sh'
        findmnt() { echo '${ROOT_DEV}'; }
        source '${REPO_ROOT}/lib/guards.sh'
        is_safe_mount_path 'Destination' '/mnt/backup' '${ROOT_DEV}'
    "

# ── Stamp file age calculation ────────────────────────────────────────────────
echo ""
echo "=== stamp file age ==="
echo ""

TMPDIR_STAMPS=$(mktemp -d)
trap 'rm -rf "$TMPDIR_STAMPS"' EXIT

STAMP="$TMPDIR_STAMPS/test.stamp"

# Use date -r for mtime (portable: GNU coreutils and BSD/macOS both support it)
_stamp_mtime() { date -r "$1" +%s; }

# Stamp touched just now — age should be 0 days
touch "$STAMP"
age=$(( ( $(date +%s) - $(_stamp_mtime "$STAMP") ) / 86400 ))
assert_eq "fresh stamp: age is 0 days" "0" "$age"

# Stamp touched 8 days ago
if touch -d "8 days ago" "$STAMP" 2>/dev/null; then
    age=$(( ( $(date +%s) - $(_stamp_mtime "$STAMP") ) / 86400 ))
else
    # BSD touch uses different syntax for relative dates
    touch -t "$(date -v-8d +%Y%m%d%H%M.%S)" "$STAMP" 2>/dev/null || touch "$STAMP"
    age=$(( ( $(date +%s) - $(_stamp_mtime "$STAMP") ) / 86400 ))
fi
[[ $age -ge 7 ]] \
    && { echo "  PASS  8-day-old stamp: age >= 7 days (got ${age})"; (( TESTS_PASS++ )) || true; } \
    || { echo "  FAIL  8-day-old stamp: expected age >= 7, got ${age}"; (( TESTS_FAIL++ )) || true; }

# Negative age guard: if stamp_mtime is in the future (clock skew), age must not go negative
stamp_mtime=$(( $(date +%s) + 3600 ))  # 1 hour in the future
raw_age=$(( ( $(date +%s) - stamp_mtime ) / 86400 ))
[[ $raw_age -lt 0 ]] && guarded_age=0 || guarded_age=$raw_age
assert_eq "clock skew: negative age clamped to 0" "0" "$guarded_age"

test_summary
