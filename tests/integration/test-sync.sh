#!/usr/bin/env bash
# tests/integration/test-sync.sh — integration tests for modules/sync/sync.sh.
#
# Runs sync.sh against real directories under /tmp — no block devices, no root,
# no production mounts or services are touched.
#
# Requires: rsync, yq (mikefarah v4) on PATH.
# Does NOT require root.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== modules/sync/sync.sh (integration) ==="
echo ""

command -v rsync &>/dev/null || { skip "all sync integration tests" "rsync not found"; test_summary; exit 0; }
command -v yq    &>/dev/null || { skip "all sync integration tests" "yq not found";    test_summary; exit 0; }

# ── Workspace (cleaned up on exit) ───────────────────────────────────────────
WORK=$(mktemp -d /tmp/nase-test-sync.XXXXXX)
TEST_CFG=$(mktemp --suffix=.yaml)
trap 'rm -rf "$WORK"; rm -f "$TEST_CFG"' EXIT

SRC="$WORK/primary/data"    # rsync source (simulates a share on the primary drive)
DST="$WORK/backup/data"     # rsync dest   (simulates a share on a backup drive)
TRASH="$WORK/trash"         # trash root
STAMPS="$WORK/stamps"       # stamp files (replaces /var/lib/nase)
LOGS="$WORK/logs"           # rsync logs   (replaces /var/log)
mkdir -p "$SRC" "$DST" "$TRASH" "$STAMPS" "$LOGS"

SYNC_SCRIPT="${REPO_ROOT}/modules/sync/sync.sh"
JOB="test-data"

# ── Config generator ──────────────────────────────────────────────────────────
# Usage: write_cfg [trash_enabled:false] [force_sync_days:7] [retention_days:30]
write_cfg() {
    local trash="${1:-false}" force="${2:-7}" retention="${3:-30}"
    cat > "$TEST_CFG" <<YAML
sync_jobs:
  - name: ${JOB}
    source: ${SRC}/
    dest: ${DST}/
    schedule: '*-*-* 03:00:00'
    rsync_flags: --archive --delete
    on_failure: ignore
    force_sync_days: ${force}
    trash:
      enabled: ${trash}
      path: ${TRASH}
      retention_days: ${retention}
notifications:
  method: none
YAML
}

# ── Sandboxed runner ──────────────────────────────────────────────────────────
run_sync() {
    CONFIG_FILE="$TEST_CFG"          \
    NASE_STAMP_DIR="$STAMPS"         \
    NASE_LOG_DIR="$LOGS"             \
    NAS_LOG="$LOGS/nase.log"         \
    NASE_SKIP_MOUNT_GUARDS=1         \
    REPO_ROOT="$REPO_ROOT"           \
    bash "$SYNC_SCRIPT" "$JOB" >"$LOGS/last-run.log" 2>&1
}

# ── State reset between tests ─────────────────────────────────────────────────
reset() {
    rm -rf "$SRC" "$DST" "$TRASH"
    rm -f  "$STAMPS/sync-${JOB}.stamp"
    mkdir -p "$SRC" "$DST" "$TRASH"
}

# ── assert_trashed DESCRIPTION FILENAME ──────────────────────────────────────
assert_trashed() {
    local desc="$1" fname="$2"
    local found
    found=$(find "$TRASH" -name "$fname" | head -1)
    if [[ -n "$found" ]]; then
        echo "  PASS  $desc"
        (( TESTS_PASS++ )) || true
    else
        echo "  FAIL  $desc — '$fname' not found anywhere under $TRASH"
        (( TESTS_FAIL++ )) || true
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: Basic copy
# Files in source are synced to an empty destination.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
mkdir -p "$SRC/subdir"
echo "world" > "$SRC/subdir/file2.txt"

run_sync
assert_file_exists "basic copy: file1.txt synced"              "$DST/file1.txt"
assert_file_exists "basic copy: subdir/file2.txt synced"       "$DST/subdir/file2.txt"
assert_file_exists "basic copy: stamp file created"            "$STAMPS/sync-${JOB}.stamp"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: Change detection — skip when source is unchanged
# A canary placed in dest after a sync survives if the next sync is skipped.
# (rsync --delete would remove it if it ran.)
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"   # ensure source is older than the stamp
run_sync                                    # first run — stamps at ~now
echo "canary" > "$DST/canary.txt"           # would be deleted if rsync ran again
run_sync                                    # second run — no source changes, should skip
assert_file_exists "skip unchanged: canary survives (rsync did not run)" "$DST/canary.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: Run when source has changed
# Adding a new file to source triggers a sync that also removes the canary.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "canary"  > "$DST/canary.txt"
echo "new"     > "$SRC/newfile.txt"    # newer than stamp → triggers sync
run_sync
assert_file_exists "run on change: newfile.txt synced"          "$DST/newfile.txt"
assert_file_absent "run on change: canary removed (--delete)"   "$DST/canary.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: Force sync after force_sync_days elapsed
# Even with no source changes, an aged stamp triggers a full sync.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg false 1   # force_sync_days=1
echo "hello" > "$SRC/file1.txt"
touch -d "3 days ago" "$SRC/file1.txt"   # source is older than any stamp we create
run_sync                                  # first run — stamp created at ~now
touch -d "2 days ago" "$STAMPS/sync-${JOB}.stamp"   # age stamp past force_sync_days
echo "canary" > "$DST/canary.txt"
run_sync   # source unchanged, but stamp age (2d) >= force_sync_days (1d) → force sync
assert_file_absent "force sync: canary removed (rsync ran via force_sync_days)" "$DST/canary.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: Trash receives files deleted from source
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg true
echo "keep"    > "$SRC/keep.txt"
echo "deleted" > "$SRC/gone.txt"
touch -d "1 minute ago" "$SRC/keep.txt" "$SRC/gone.txt"
run_sync                      # first sync — both files copied
rm "$SRC/gone.txt"            # delete from source
run_sync                      # second sync — gone.txt should be trashed, not just deleted
assert_file_absent "trash: gone.txt removed from dest root"     "$DST/gone.txt"
assert_trashed     "trash: gone.txt moved into trash dir"       "gone.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: Trash pruning removes directories older than retention_days
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg true 7 30
OLD_TRASH_DIR="$TRASH/2020-01-01_000000"
mkdir -p "$OLD_TRASH_DIR"
touch -d "40 days ago" "$OLD_TRASH_DIR"   # 40 days > retention_days=30
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync   # triggers pruning after successful rsync
assert_dir_absent "trash pruning: dir older than retention_days removed" "$OLD_TRASH_DIR"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: Missing source — graceful skip (exit 0)
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
rm -rf "$SRC"   # source directory does not exist
assert_exit0 "missing source: exits 0 (graceful skip)" run_sync

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: Missing dest parent — graceful skip (exit 0)
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
rm -rf "$WORK/backup"   # dest parent gone
assert_exit0 "missing dest: exits 0 (graceful skip)" run_sync

# ─────────────────────────────────────────────────────────────────────────────
# Test 9: Change detection names what triggered it
# A job whose detection fires nightly while rsync transfers nothing is
# otherwise indistinguishable from one with real changes (backlog #4), so the
# triggering path and its mtime have to be in the log. Asserted against the
# detection line alone — the filename also shows up in rsync's transfer list,
# which would make these pass without the log line existing at all.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync                                   # first run creates the stamp
echo "changed" > "$SRC/trigger.txt"        # newer than the stamp
touch -d "1 minute ago" "$SRC"             # ...but the dir itself is not, so
                                           # find reports the file, not its parent
: > "$LOGS/nase.log"
run_sync
DETECTED=$(grep "changes detected" "$LOGS/nase.log" || true)
assert_contains "detection log: names the triggering path" "trigger.txt" "$DETECTED"
assert_contains "detection log: reports its mtime"         "mtime"       "$DETECTED"

# ─────────────────────────────────────────────────────────────────────────────
# Test 10: A future-dated mtime is reported, not silently re-triggering
# This is the shape backlog #4 suspects behind the nightly movies sync: a file
# the stamp can never overtake, so detection fires every night while rsync has
# nothing to send.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync                                   # stamp is now "just now"
echo "from the future" > "$SRC/tomorrow.txt"
touch -d "tomorrow" "$SRC/tomorrow.txt"
touch -d "1 minute ago" "$SRC"
: > "$LOGS/nase.log"
run_sync
DETECTED=$(grep "changes detected" "$LOGS/nase.log" || true)
assert_contains "future mtime: detection names the offending file" "tomorrow.txt" "$DETECTED"

# A second run with nothing else touched must fire again — that is the
# permanence which makes this shape worth naming in the log.
: > "$LOGS/nase.log"
run_sync
DETECTED=$(grep "changes detected" "$LOGS/nase.log" || true)
assert_contains "future mtime: still fires on the next run" "tomorrow.txt" "$DETECTED"

# ─────────────────────────────────────────────────────────────────────────────
# Test 11: The skip line reports how old the stamp is
# Without it there is no way to tell a job that skipped yesterday from one that
# has not run in a month, which is what force_sync_days is judged against.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
: > "$LOGS/nase.log"
run_sync                                   # nothing changed -> skip
LOG_OUT=$(cat "$LOGS/nase.log")
assert_contains "skip log: says no changes"        "no changes since last sync" "$LOG_OUT"
assert_contains "skip log: reports the stamp age"  "stamp 0d old"               "$LOG_OUT"

test_summary
