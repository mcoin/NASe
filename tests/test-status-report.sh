#!/usr/bin/env bash
# tests/test-status-report.sh — modules/status-report/report.sh (backlog #29).
#
# Three things went wrong with the report and all three were silent: it named
# per-job sync timers that #4 had already deleted (nine false anomalies every
# week), it reported the watcher's own heartbeat and NASe's own config
# snapshots as user file activity, and it read each drive's integrity manifest
# straight off the platter, waking both drives every run. The last one is the
# reason these tests never touch a real drive: the whole point of the fix is
# that the report reads the SD-card cache, so the suite asserts it can produce
# a complete integrity section with no manifest present at all.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/config.sh"

echo "=== modules/status-report/report.sh ==="
echo ""

WORK=$(mktemp -d /tmp/nase-test-status-report.XXXXXX)
trap 'rm -rf "$WORK"' EXIT
RR="${WORK}/repo"
STAMPS="${WORK}/stamps"
STUBS="${WORK}/stubs"
mkdir -p "$RR/modules/sync" "$STAMPS/integrity-status" "$STUBS"

# A fake repo root: real code, stubbed notifier, so the report's body is
# captured on stdout instead of mailed.
ln -s "${REPO_ROOT}/lib"                  "$RR/lib"
ln -s "${REPO_ROOT}/modules/integrity"    "$RR/modules/integrity"
ln -s "${REPO_ROOT}/modules/status-report" "$RR/modules/status-report"
cat > "$RR/modules/sync/notify.sh" <<'STUB'
#!/usr/bin/env bash
cat
STUB
chmod +x "$RR/modules/sync/notify.sh"

# systemctl stub: every unit is active unless named in INACTIVE_UNITS. Mirrors
# the real thing's contract — print the state, exit non-zero when not active.
cat > "${STUBS}/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "is-active" ]]; then
    if [[ " ${INACTIVE_UNITS:-} " == *" $2 "* ]]; then
        echo "inactive"; exit 3
    fi
    echo "active"; exit 0
fi
exit 0
STUB
chmod +x "${STUBS}/systemctl"

cat > "$RR/config.yaml" <<'YAML'
nas:
  hostname: test-nas
drives:
  - name: primary
    uuid: test-uuid-primary
    mountpoint: /mnt/primary
    active: true
    spindown_min: 60
config_archive:
  dest: /mnt/primary/backups/NASe
  schedule: '*-*-* 02:00:00'
sync_jobs:
  - name: alpha
    source: /mnt/primary/alpha/
    dest: /mnt/backup_daily/alpha/
    schedule: '*-*-* 03:00:00'
  - name: beta
    source: /mnt/primary/beta/
    dest: /mnt/backup_daily/beta/
    schedule: '*-*-* 03:00:00'
  - name: gamma
    source: /mnt/primary/gamma/
    dest: /mnt/backup_daily/gamma/
    schedule: '*-*-* 05:30:00'
integrity:
  enabled: true
status_report:
  enabled: true
notifications:
  method: none
YAML

NOW=$(date +%s)
# Events log: two real changes, plus the three kinds of entry that used to be
# reported as file activity and are not.
cat > "${STAMPS}/primary-events.log" <<EOF
$(date -d "@$((NOW - 3600))" '+%Y-%m-%d %H:%M:%S')	create	/mnt/primary/photo/holiday.jpg
$(date -d "@$((NOW - 3500))" '+%Y-%m-%d %H:%M:%S')	modify	/mnt/primary/music/album/track.flac
$(date -d "@$((NOW - 3400))" '+%Y-%m-%d %H:%M:%S')	__heartbeat__	-
$(date -d "@$((NOW - 3300))" '+%Y-%m-%d %H:%M:%S')	__gap__	watcher started (events during downtime were not recorded)
$(date -d "@$((NOW - 3200))" '+%Y-%m-%d %H:%M:%S')	create	/mnt/primary/backups/NASe/2026-09-10T00-00-02Z/config.yaml
$(date -d "@$((NOW - 3100))" '+%Y-%m-%d %H:%M:%S')	modify	/mnt/primary/.nase/tmp/scratch
EOF

# Integrity status cache — and deliberately NO manifest on any "drive".
cat > "${STAMPS}/integrity-status/mnt-primary.json" <<EOF
{"has_manifest":true,"total":1000,"ok":999,"flagged":1,
 "discovery_complete":false,"discovery_total":"2000","discovery_cursor_n":"1500",
 "flagged_truncated":false,"updated_at":${NOW},
 "flagged_rows":[{"path":"movies/bad.mkv","last_checked":${NOW},"event_type":"mismatch","detail":"checksum changed"}],
 "recent_events":[{"ts":$((NOW - 600)),"event_type":"mismatch","path":"movies/bad.mkv","detail":"checksum changed"},
                  {"ts":$((NOW - 99999999)),"event_type":"missing","path":"ancient.txt","detail":"before the window"}]}
EOF

run_report() {
    env PATH="${STUBS}:${PATH}" \
        REPO_ROOT="$RR" \
        NASE_STAMP_DIR="$STAMPS" \
        NAS_LOG="${WORK}/nase.log" \
        INACTIVE_UNITS="${INACTIVE_UNITS:-}" \
        bash "${REPO_ROOT}/modules/status-report/report.sh" 2>/dev/null
}

REPORT=$(run_report)

# ── Sync timers: group units, not the per-job ones #4 deleted ─────────────────
assert_contains "reports timers as all active when the group timer is up" \
    "Sync timers: all active" "$REPORT"
assert_not_contains "never names a per-job timer" \
    "nase-sync-alpha.timer" "$REPORT"
assert_not_contains "and does not invent anomalies for them" \
    "is inactive" "$REPORT"

INACTIVE_UNITS="nase-sync-group-03-00-00.timer"
REPORT_DOWN=$(run_report)
unset INACTIVE_UNITS
assert_contains "a down group timer is named by its group unit" \
    "nase-sync-group-03-00-00.timer: inactive" "$REPORT_DOWN"
assert_contains "and raised as an anomaly" \
    "Sync timer 'nase-sync-group-03-00-00.timer' is inactive" "$REPORT_DOWN"
# `systemctl is-active` prints the state *and* exits non-zero; the old
# `|| echo unknown` appended a second line, so the report read "inactive"
# then "unknown" on the next line for every one of the nine jobs.
assert_not_contains "a non-zero is-active does not also print 'unknown'" \
    "unknown" "$REPORT_DOWN"
# Two jobs share the 03:00 schedule and must collapse to one timer check.
assert_eq "one check per schedule, not per job" "1" \
    "$(grep -c 'nase-sync-group-03-00-00.timer: inactive' <<< "$REPORT_DOWN")"

# ── File changes: real activity only ─────────────────────────────────────────
assert_contains "reports a real file change" "holiday.jpg" "$REPORT"
assert_contains "reports another real file change" "track.flac" "$REPORT"
assert_not_contains "watcher heartbeats are not file activity" \
    "__heartbeat__" "$REPORT"
assert_not_contains "nor are watcher restart gaps" "__gap__" "$REPORT"
assert_not_contains "nor is NASe's own config archive" \
    "2026-09-10T00-00-02Z" "$REPORT"
assert_not_contains "nor the integrity manifest's own churn" \
    ".nase/tmp/scratch" "$REPORT"
assert_contains "counts only the real changes" "2 file(s) changed" "$REPORT"

# ── Integrity: from the SD-card cache, with no manifest present ──────────────
# This is the fix for the drive wake: every figure below comes from the cache,
# and there is no integrity.db anywhere in this test.
assert_contains "file counts come from the cache" \
    "files: 1000   ok: 999   flagged: 1" "$REPORT"
assert_contains "discovery progress comes from the cache" \
    "discovery: in progress (1500/2000)" "$REPORT"
assert_contains "recent check events come from the cache" \
    "mismatch   movies/bad.mkv (checksum changed)" "$REPORT"
assert_not_contains "events older than the window are not reported" \
    "ancient.txt" "$REPORT"
assert_contains "flagged files come from the cache" "movies/bad.mkv" "$REPORT"
assert_contains "a flagged file is an anomaly" \
    "1 flagged file(s) on drive 'primary'" "$REPORT"

# Freshness has to be visible: the cache is only rewritten when integrity runs,
# which since #4 is roughly weekly, so the figures can be days stale.
assert_contains "states when the figures are from" "as of " "$REPORT"
python3 - "${STAMPS}/integrity-status/mnt-primary.json" <<'PY'
import json, sys, time
p = sys.argv[1]
d = json.load(open(p))
d["updated_at"] = int(time.time()) - 3 * 86400
json.dump(d, open(p, "w"))
PY
REPORT_STALE=$(run_report)
assert_contains "and says how stale they are" \
    "(3d ago — updated when integrity last ran)" "$REPORT_STALE"

# ── Missing cache degrades, it does not crash or reach for the drive ─────────
rm -f "${STAMPS}/integrity-status/mnt-primary.json"
REPORT_NOCACHE=$(run_report)
assert_contains "a missing cache is reported, not fatal" \
    "no manifest status recorded yet" "$REPORT_NOCACHE"
assert_contains "and the rest of the report still renders" \
    "=== FILE CHANGES" "$REPORT_NOCACHE"

test_summary
