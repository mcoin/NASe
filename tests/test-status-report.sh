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

# ── Reports are archived to the SD card (#37) ─────────────────────────────────
# Before this, every report NASe produced existed only in the mailbox it was
# sent to: report.sh composed the body into a variable, piped it to the
# notifier, and exited.
REPORTS="${STAMPS}/reports"

# Self-contained: earlier blocks in this suite deliberately delete the integrity
# cache and leave a status-report stamp behind, so without restoring both the
# report here legitimately has nothing to report and the counts below would be
# asserting the wrong thing for the right reason.
cat > "${STAMPS}/integrity-status/mnt-primary.json" <<EOF
{"has_manifest":true,"total":1000,"ok":999,"flagged":1,
 "discovery_complete":false,"discovery_total":"2000","discovery_cursor_n":"1500",
 "flagged_truncated":false,"updated_at":${NOW},
 "flagged_rows":[{"path":"movies/bad.mkv","last_checked":${NOW},"event_type":"mismatch","detail":"checksum changed"}],
 "recent_events":[]}
EOF
rm -f "${STAMPS}/status-report.stamp"

rm -rf "$REPORTS"
run_report >/dev/null
assert_eq "one report file is written" "1" "$(ls -1 "$REPORTS"/*.json 2>/dev/null | wc -l)"

REPORT_JSON=$(ls -1 "$REPORTS"/*.json | head -1)
assert_exit0 "the archived report is valid JSON" \
    python3 -c "import json,sys; json.load(open(sys.argv[1]))" "$REPORT_JSON"

field() { python3 -c "import json,sys; print(json.load(open(sys.argv[1]))[sys.argv[2]])" "$REPORT_JSON" "$1"; }

# The metadata is what the list view renders, so it has to match the body it
# was written with rather than be re-derived from the rendered text later.
assert_eq "records the anomaly count"  "1" "$(field anomalies)"
assert_eq "records the change count"   "2" "$(field changes)"
assert_contains "records the subject"  "NASe status report" "$(field subject)"
assert_contains "records the body"     "=== SYSTEM STATUS ===" "$(field body)"
assert_contains "the body is the whole report" "INTEGRITY STATUS" "$(field body)"
assert_eq "defaults to the scheduled trigger" "scheduled" "$(field trigger)"
assert_eq "names the file after generated_at" \
    "$(field generated_at).json" "$(basename "$REPORT_JSON")"

# An interactive run is distinguishable from the timer's.
rm -rf "$REPORTS"
rm -f "${STAMPS}/status-report.stamp"
NASE_REPORT_TRIGGER=manual run_report >/dev/null
REPORT_JSON=$(ls -1 "$REPORTS"/*.json | head -1)
assert_eq "an interactive run is marked manual" "manual" "$(field trigger)"

# Nothing prunes: keeping every report is the decision on #37.
sleep 1
run_report >/dev/null
assert_eq "a second run adds a file rather than replacing one" "2" \
    "$(ls -1 "$REPORTS"/*.json | wc -l)"

# The report is most worth having when delivery failed, which is why the
# archive is written before the notifier rather than after it.
rm -rf "$REPORTS"
cat > "$RR/modules/sync/notify.sh" <<'STUB'
#!/usr/bin/env bash
cat >/dev/null
echo "delivery exploded" >&2
exit 1
STUB
chmod +x "$RR/modules/sync/notify.sh"
run_report >/dev/null 2>&1 || true
assert_eq "archived even when the notifier fails" "1" \
    "$(ls -1 "$REPORTS"/*.json 2>/dev/null | wc -l)"
# Restore the passthrough notifier for anything after this.
printf '#!/usr/bin/env bash\ncat\n' > "$RR/modules/sync/notify.sh"
chmod +x "$RR/modules/sync/notify.sh"

# No temp files are left behind by the atomic write.
assert_eq "no .tmp files left in the reports directory" "0" \
    "$(ls -1 "$REPORTS"/*.tmp 2>/dev/null | wc -l)"

# ── status_report.enabled: false actually disables the report (#40) ───────────
# It did not: the guard read `.status_report.enabled // "true"`, and `//` yields
# its default for a false as well as for an absent key, so a configured false
# came back as "true" and the report kept composing, archiving and mailing. Both
# directions are asserted, because inverting the broken condition would pass the
# negative case alone.
set_enabled() {
    python3 - "$RR/config.yaml" "$1" <<'EOF'
import re, sys
p, val = sys.argv[1], sys.argv[2]
s = open(p).read()
s, n = re.subn(r"(status_report:\n  enabled: )\w+", r"\g<1>" + val, s)
assert n == 1, "status_report.enabled not found in the test config"
open(p, "w").write(s)
EOF
}

rm -rf "$REPORTS"
rm -f "${STAMPS}/status-report.stamp"
set_enabled false
REPORT_OFF=$(run_report)
assert_contains "a configured false is honoured"     "Status report disabled" "$REPORT_OFF"
assert_not_contains "no report body is composed when disabled"     "=== SYSTEM STATUS ===" "$REPORT_OFF"
assert_eq "and nothing is archived when disabled" "0" \
    "$(ls -1 "$REPORTS"/*.json 2>/dev/null | wc -l)"

set_enabled true
REPORT_ON=$(run_report)
assert_contains "a configured true still runs" \
    "=== SYSTEM STATUS ===" "$REPORT_ON"
assert_eq "and still archives" "1" \
    "$(ls -1 "$REPORTS"/*.json 2>/dev/null | wc -l)"

# Absent means enabled: the dropped `// "true"` default was expressing that, and
# it has to survive without the operator that could not tell false from missing.
rm -rf "$REPORTS"
rm -f "${STAMPS}/status-report.stamp"
python3 - "$RR/config.yaml" <<'EOF'
import re, sys
p = sys.argv[1]
s = open(p).read()
open(p, "w").write(re.sub(r"status_report:\n  enabled: \w+\n", "", s))
EOF
REPORT_ABSENT=$(run_report)
assert_contains "an absent status_report.enabled means enabled" \
    "=== SYSTEM STATUS ===" "$REPORT_ABSENT"

test_summary
