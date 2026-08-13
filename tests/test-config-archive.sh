#!/usr/bin/env bash
# tests/test-config-archive.sh — tests for modules/config-archive/archive.sh.
#
# Runs the real script against directories under /tmp: no drives, no root, no
# production state. The property that matters most here is the negative one —
# that a run which has nothing to do never touches the destination, because
# that is what keeps the drive asleep (backlog #4).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== modules/config-archive/archive.sh ==="
echo ""

command -v yq &>/dev/null || { skip "all config-archive tests" "yq not found"; test_summary; exit 0; }

WORK=$(mktemp -d /tmp/nase-test-archive.XXXXXX)
trap 'rm -rf "$WORK"' EXIT

DEST="$WORK/dest"          # stands in for /mnt/primary/backups/NASe
STAMPS="$WORK/stamps"      # stands in for /var/lib/nase
FAKE_REPO="$WORK/repo"     # holds config.yaml, as REPO_ROOT would
LOGS="$WORK/logs"
mkdir -p "$DEST" "$STAMPS" "$FAKE_REPO" "$LOGS"

BACKLOG="$STAMPS/backlog.json"
TEST_CFG="$FAKE_REPO/config.yaml"

TODAY_DOW=$(LC_ALL=C date +%a)
OTHER_DOW=$(LC_ALL=C date -d tomorrow +%a)

# write_cfg [flush_calendar] [flush_max_age_days]
write_cfg() {
    local cal="${1:-}" max_age="${2:-10}"
    cat > "$TEST_CFG" <<YAML
nas:
  hostname: test
drives:
  - name: primary
    uuid: "00000000-0000-0000-0000-000000000001"
    mountpoint: ${WORK}
    filesystem: ext4
    role: main
config_archive:
  dest: ${DEST}
  retention_days: 90
  flush_calendar: '${cal}'
  flush_max_age_days: ${max_age}
sync_jobs: []
notifications:
  method: none
YAML
}

run_archive() {
    CONFIG_FILE="$TEST_CFG"              \
    NASE_STAMP_DIR="$STAMPS"             \
    NASE_BACKLOG_FILE="$BACKLOG"         \
    NAS_LOG="$LOGS/nase.log"             \
    REPO_ROOT="$FAKE_REPO"               \
    bash "${REPO_ROOT}/modules/config-archive/archive.sh" >"$LOGS/last.log" 2>&1
}

# The script resolves lib/ and spin_status.sh from REPO_ROOT, so the fake repo
# needs those — symlinked, so the real code under test is what runs.
ln -sfn "${REPO_ROOT}/lib" "$FAKE_REPO/lib"
ln -sfn "${REPO_ROOT}/modules" "$FAKE_REPO/modules"

reset() {
    rm -rf "$DEST" "$STAMPS"
    mkdir -p "$DEST" "$STAMPS"
    echo '{"items": [{"id": 1, "title": "a ticket"}], "next_id": 2}' > "$BACKLOG"
    : > "$LOGS/nase.log"
}

snapshot_count() { find "$DEST" -mindepth 1 -maxdepth 1 -type d | wc -l | tr -d ' '; }

# ─────────────────────────────────────────────────────────────────────────────
# Test 1: first run archives both state files
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg "$TODAY_DOW"
run_archive
assert_eq "first run: one snapshot written" "1" "$(snapshot_count)"
assert_file_exists "first run: backlog archived"     "$DEST/backlog.json"
assert_file_exists "first run: config archived"      "$DEST/config.yaml"

# ─────────────────────────────────────────────────────────────────────────────
# Test 2: nothing changed -> the destination is not touched at all
# This is the property that keeps the drive asleep.
# ─────────────────────────────────────────────────────────────────────────────
before=$(snapshot_count)
: > "$LOGS/nase.log"
run_archive
assert_eq "unchanged: no new snapshot" "$before" "$(snapshot_count)"
assert_contains "unchanged: says it did not touch the drive" \
    "no drive access" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 3: a backlog edit on a non-pinned day is held on the SD card
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg "$OTHER_DOW"
run_archive                                  # seed the hashes
before=$(snapshot_count)
echo '{"items": [{"id": 1, "title": "edited"}], "next_id": 2}' > "$BACKLOG"
: > "$LOGS/nase.log"
run_archive
assert_eq "unpinned day: no new snapshot" "$before" "$(snapshot_count)"
assert_contains "unpinned day: change recorded as pending" \
    "Holding" "$(cat "$LOGS/nase.log")"
assert_file_exists "unpinned day: pending stamp written" "$STAMPS/config-archive-pending.stamp"

# ─────────────────────────────────────────────────────────────────────────────
# Test 4: the same edit flushes on the pinned day
# ─────────────────────────────────────────────────────────────────────────────
write_cfg "$TODAY_DOW"
: > "$LOGS/nase.log"
run_archive
assert_eq "pinned day: snapshot written" "$((before + 1))" "$(snapshot_count)"
assert_file_absent "pinned day: pending stamp cleared" "$STAMPS/config-archive-pending.stamp"
assert_contains "pinned day: archived copy has the edit" \
    "edited" "$(cat "$DEST/backlog.json")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 5: safety net — a pending change older than flush_max_age_days flushes
# anyway, so a missed pinned day cannot become "never archived"
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg "$OTHER_DOW" 10
run_archive
before=$(snapshot_count)
echo '{"items": [{"id": 1, "title": "old pending edit"}], "next_id": 2}' > "$BACKLOG"
run_archive                                   # holds it, writes the pending stamp
date -d "20 days ago" +%s > "$STAMPS/config-archive-pending.stamp"
: > "$LOGS/nase.log"
run_archive
assert_eq "max age: snapshot written past the missed day" "$((before + 1))" "$(snapshot_count)"
assert_contains "max age: logged as the reason" "pending for 20d" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 6: a torn backlog is never promoted over a good snapshot
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg "$TODAY_DOW"
run_archive
printf '{"items": [{"id": 1, "titl' > "$BACKLOG"     # truncated mid-write
: > "$LOGS/nase.log"
run_archive
assert_contains "torn json: skipped with a warning" "not valid JSON" "$(cat "$LOGS/nase.log")"
assert_contains "torn json: good copy still on the drive" \
    "a ticket" "$(cat "$DEST/backlog.json")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 7: an unparseable flush_calendar archives now rather than never
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg "Thurs-day"
: > "$LOGS/nase.log"
run_archive
assert_eq "invalid spec: archived anyway" "1" "$(snapshot_count)"
assert_contains "invalid spec: warned" "not a valid systemd calendar" "$(cat "$LOGS/nase.log")"

# ─────────────────────────────────────────────────────────────────────────────
# Test 8: no flush_calendar at all keeps the original write-on-change behaviour
# ─────────────────────────────────────────────────────────────────────────────
reset; write_cfg ""
run_archive
before=$(snapshot_count)
echo '{"items": [{"id": 2, "title": "another"}], "next_id": 3}' > "$BACKLOG"
run_archive
assert_eq "no pin: writes on change as before" "$((before + 1))" "$(snapshot_count)"

test_summary
