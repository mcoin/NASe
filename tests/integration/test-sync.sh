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


# ── Config generator: forced sync pinned to a calendar day ───────────────────
# Usage: write_cfg_calendar SPEC [max_age_days:45] [force_sync_days:0]
write_cfg_calendar() {
    local spec="$1" max_age="${2:-45}" force_days="${3:-0}"
    cat > "$TEST_CFG" <<YAML
sync_jobs:
  - name: ${JOB}
    source: ${SRC}/
    dest: ${DST}/
    schedule: '*-*-* 03:00:00'
    rsync_flags: --archive --delete
    on_failure: ignore
    force_sync_days: ${force_days}
    force_sync_calendar: '${spec}'
    force_sync_max_age_days: ${max_age}
    trash:
      enabled: false
YAML
}

# quiesce SOURCE_AGE STAMP_AGE
# Put the source tree far enough in the past that change detection finds
# nothing, then set the stamp to the wanted age. Ageing the files alone is not
# enough: creating or removing anything bumps the *directory's* mtime, and find
# reports the directory, so a test meaning to exercise the forced-sync path
# would silently be exercising ordinary change detection instead.
quiesce() {
    local source_age="$1" stamp_age="$2"
    find "$SRC" -exec touch -d "$source_age" {} +
    touch -d "$stamp_age" "$STAMPS/sync-${JOB}.stamp"
}

# Weekday names for "today" and "a day that is not today", so these tests give
# the same answer whichever day the suite happens to run on.
TODAY_DOW=$(LC_ALL=C date +%a)
OTHER_DOW=$(LC_ALL=C date -d tomorrow +%a)

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

# ...and it must be called out as a future date, not just named. Asserted
# against the WARN line alone: the detection line above already contains both
# the filename and the word "mtime", so grepping the whole log would pass
# whether or not the warning exists.
WARNED=$(grep "WARN" "$LOGS/nase.log" | grep "future" || true)
assert_contains "future mtime: warns that the date is in the future" "tomorrow.txt" "$WARNED"
assert_contains "future mtime: warning explains the nightly no-op"   "transfers nothing" "$WARNED"

# A normal recent mtime must not trip the warning, or it becomes noise that
# gets filtered out and stops meaning anything.
reset; write_cfg
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "changed" > "$SRC/trigger.txt"
touch -d "1 minute ago" "$SRC"
: > "$LOGS/nase.log"
run_sync
WARNED=$(grep "WARN" "$LOGS/nase.log" | grep "future" || true)
assert_empty "past mtime: no future-date warning" "$WARNED"

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

# ─────────────────────────────────────────────────────────────────────────────
# Test 12: force_sync_calendar forces a sync on the pinned day
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg_calendar "$TODAY_DOW"
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync                                    # first run creates the stamp
quiesce "10 days ago" "3 days ago"
echo "canary" > "$DST/canary.txt"
: > "$LOGS/nase.log"
run_sync
assert_file_absent "calendar: pinned day forces a sync (canary deleted)" "$DST/canary.txt"
assert_contains "calendar: log names the matching spec" \
    "matches force_sync_calendar" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 13: no sync on a day that is not pinned
# The whole point of pinning: an unpinned day must not wake the backup drive,
# however long ago the job last ran (short of the safety net below).
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg_calendar "$OTHER_DOW"
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
quiesce "10 days ago" "3 days ago"
echo "canary" > "$DST/canary.txt"
: > "$LOGS/nase.log"
run_sync
assert_file_exists "calendar: unpinned day does not sync (canary survives)" "$DST/canary.txt"
assert_contains "calendar: unpinned day logs a skip" \
    "no changes since last sync" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 14: force_sync_max_age_days is the safety net
# A pinned schedule that stops firing (Pi powered off on the day, spec that no
# longer matches) must not silently decay into "never".
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg_calendar "$OTHER_DOW" 10
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
quiesce "30 days ago" "20 days ago"   # 20d stamp > max_age 10d
echo "canary" > "$DST/canary.txt"
: > "$LOGS/nase.log"
run_sync
assert_file_absent "calendar: max age forces a sync past the missed day" "$DST/canary.txt"
assert_contains "calendar: max-age force is logged as a warning" \
    "has not fired" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 15: at most one forced run per pinned day
# The timer fires daily; the pin must not re-force on every firing.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg_calendar "$TODAY_DOW"
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
quiesce "10 days ago" "3 days ago"
run_sync                                    # the pinned run; stamp is now today
echo "canary" > "$DST/canary.txt"
: > "$LOGS/nase.log"
run_sync                                    # same day again -> must not force
assert_file_exists "calendar: second run on the pinned day does not sync" "$DST/canary.txt"

# ─────────────────────────────────────────────────────────────────────────────
# Test 16: an unparseable spec warns and falls back to force_sync_days
# Silently never forcing again would be worse than not pinning at all.
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg_calendar "Thurs-day" 45 2
echo "hello" > "$SRC/file1.txt"
touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
quiesce "10 days ago" "5 days ago"     # 5d stamp > force_sync_days 2
echo "canary" > "$DST/canary.txt"
: > "$LOGS/nase.log"
run_sync
LOG_OUT=$(cat "$LOGS/nase.log")
assert_contains  "calendar: invalid spec warns"            "not a valid systemd calendar" "$LOG_OUT"
assert_file_absent "calendar: invalid spec falls back to force_sync_days" "$DST/canary.txt"


# ═════════════════════════════════════════════════════════════════════════════
# Change detection from the primary-watch event log (backlog #4 phase 2 opt A)
#
# The point of this path is that a quiet night costs no drive access at all.
# So the decisive assertion is not "it noticed a change" but the opposite: a
# file that `find -newer` *would* have caught must be ignored when the event
# log says nothing happened. That can only pass if the source was never walked.
# ═════════════════════════════════════════════════════════════════════════════
EVENTS="$STAMPS/primary-events.log"

# Seed an event log the watcher could plausibly have written: coverage starting
# an hour ago, a heartbeat just now, and whatever lines the caller adds.
seed_events() {
    mkdir -p "$STAMPS"
    {
        date -d '1 hour ago' '+%Y-%m-%d %H:%M:%S'    | tr -d '\n'; printf '\t__heartbeat__\t-\n'
        for extra in "$@"; do printf '%s\n' "$extra"; done
        date '+%Y-%m-%d %H:%M:%S'                    | tr -d '\n'; printf '\t__heartbeat__\t-\n'
    } > "$EVENTS"
}
ev() { printf '%s\t%s\t%s' "$(date -d "$1" '+%Y-%m-%d %H:%M:%S')" "$2" "$3"; }

# ── Quiet watcher: source is never scanned ────────────────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync                                    # creates the stamp
echo "invisible" > "$SRC/unlogged.txt"      # newer than the stamp -> find WOULD see it
seed_events                                 # ...but the event log knows nothing
: > "$LOGS/nase.log"
run_sync
SKIP=$(grep "no changes since last sync" "$LOGS/nase.log" || true)
assert_contains "watcher: quiet log means skip"          "skipping"    "$SKIP"
assert_contains "watcher: skip names the event log"      "via watcher" "$SKIP"
assert_not_contains "watcher: the source was not walked" "unlogged.txt" \
    "$(cat "$LOGS/nase.log")"

# ── A logged event is detected, and named from the log ────────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
seed_events "$(ev 'now' modify "$SRC/real.txt")"
: > "$LOGS/nase.log"
run_sync
DET=$(grep "changes detected" "$LOGS/nase.log" || true)
assert_contains "watcher: detects a logged event"        "real.txt"       "$DET"
assert_contains "watcher: says it came from the log"     "from event log" "$DET"

# ── An event outside this job's source must not trigger it ────────────────────
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
seed_events "$(ev 'now' modify "/somewhere/else/other.txt")"
: > "$LOGS/nase.log"
run_sync
assert_contains "watcher: ignores events outside the source" "skipping" \
    "$(grep 'no changes since last sync' "$LOGS/nase.log" || true)"

# ── Cannot vouch -> fall back to find, and say why ────────────────────────────
# Each of these is a way the log could lie by omission. Falling back costs a
# drive read; trusting it would silently stop syncing, so the bias is correct.
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "real change" > "$SRC/found-by-find.txt"
touch -d "1 minute ago" "$SRC"   # else find reports the parent dir, not the file
seed_events "$(ev 'now' __gap__ 'watcher started')"
: > "$LOGS/nase.log"
run_sync
assert_contains "gap in window: falls back to find" "falling back to scanning" \
    "$(cat "$LOGS/nase.log")"
assert_contains "gap in window: the fallback finds the change" "found-by-find.txt" \
    "$(grep 'changes detected' "$LOGS/nase.log" || true)"

# A watcher that has not spoken in hours may be dead; silence is not evidence.
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "real change" > "$SRC/stale-case.txt"
{ date -d '3 hours ago' '+%Y-%m-%d %H:%M:%S' | tr -d '\n'; printf '\t__heartbeat__\t-\n'; } > "$EVENTS"
: > "$LOGS/nase.log"
run_sync
assert_contains "stale watcher: falls back to find" "may be dead" "$(cat "$LOGS/nase.log")"

# No log at all (fresh install, or the watcher never started).
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "real change" > "$SRC/nolog.txt"
touch -d "1 minute ago" "$SRC"   # else find reports the parent dir, not the file
rm -f "$EVENTS"
: > "$LOGS/nase.log"
run_sync
assert_contains "missing log: falls back to find" "not readable" "$(cat "$LOGS/nase.log")"
assert_contains "missing log: the fallback finds the change" "nolog.txt" \
    "$(grep 'changes detected' "$LOGS/nase.log" || true)"

# Log that starts after the stamp cannot describe the whole window.
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync
echo "real change" > "$SRC/short-log.txt"
# Age the stamp explicitly. Both timestamps have one-second resolution, so a
# stamp written in the same second as the log's first line would compare equal
# and the log would appear to cover the window.
touch -d "10 minutes ago" "$STAMPS/sync-${JOB}.stamp"
{ date '+%Y-%m-%d %H:%M:%S' | tr -d '\n'; printf '\t__heartbeat__\t-\n'; } > "$EVENTS"
: > "$LOGS/nase.log"
run_sync
assert_contains "log younger than stamp: falls back" "window not covered" \
    "$(cat "$LOGS/nase.log")"


# ── The detection cursor survives a watcher restart ───────────────────────────
# Every apply.sh restarts the watcher, which writes a __gap__. Without a cursor
# that gap sits after the sync stamp until something actually syncs, so every
# night would fall back to scanning the drive — exactly the cost phase 2 exists
# to remove. The cursor records "confirmed unchanged at T" independently of
# whether rsync ran.
reset; write_cfg
echo "hello" > "$SRC/file1.txt"; touch -d "1 minute ago" "$SRC/file1.txt"
run_sync                                        # stamp created
# Age the whole source tree, not just the stamp: creating file1.txt bumped the
# directory's mtime, and find reports the directory — night one would detect a
# "change", sync, and move the stamp past the gap, making night two pass for
# entirely the wrong reason.
quiesce "30 minutes ago" "10 minutes ago"
rm -f "$STAMPS/detect-${JOB}.cursor"

# Night one: a gap after the stamp forces the fallback, which finds nothing.
seed_events "$(ev '5 minutes ago' __gap__ 'watcher started')"
: > "$LOGS/nase.log"
run_sync
assert_contains "cursor: night one falls back past the gap" "falling back to scanning" \
    "$(cat "$LOGS/nase.log")"
assert_file_exists "cursor: written after a clean detection" "$STAMPS/detect-${JOB}.cursor"

# Night two: same gap, still older than the stamp — but now the cursor is newer
# than it, so the watcher can vouch and the drive is not touched.
: > "$LOGS/nase.log"
run_sync
SKIP2=$(grep "no changes since last sync" "$LOGS/nase.log" || true)
assert_contains "cursor: night two uses the watcher" "via watcher" "$SKIP2"
assert_not_contains "cursor: night two does not fall back" "falling back" \
    "$(cat "$LOGS/nase.log")"

test_summary
