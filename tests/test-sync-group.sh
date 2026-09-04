#!/usr/bin/env bash
# tests/test-sync-group.sh — modules/sync/run-group.sh and the wake-attribution
# ledger it writes (backlog #4, phase 2 option C).
#
# Serialising the jobs is only half the point; the other half is that wake
# attribution has a trustworthy source. These tests cover both, plus the slug
# agreement between the shell (which names the units) and the Python dashboard
# (which reads those names back).
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"
source "${REPO_ROOT}/lib/config.sh"

echo "=== modules/sync/run-group.sh ==="
echo ""

WORK=$(mktemp -d /tmp/nase-test-sync-group.XXXXXX)
STUBS="${WORK}/stubs"
TEST_CFG="${WORK}/config.yaml"
STAMPS="${WORK}/stamps"
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$STUBS" "$STAMPS"

# systemctl stub: records the units it was asked to start, in order, and fails
# for any unit named in FAIL_UNITS.
cat > "${STUBS}/systemctl" <<'STUB'
#!/usr/bin/env bash
if [[ "$1" == "start" ]]; then
    shift
    [[ "$1" == "--wait" ]] && shift
    echo "$1" >> "$SYSTEMCTL_CALLS"
    for f in ${FAIL_UNITS:-}; do
        [[ "$1" == "$f" ]] && exit 1
    done
fi
exit 0
STUB
chmod +x "${STUBS}/systemctl"
export PATH="${STUBS}:${PATH}"
export SYSTEMCTL_CALLS="${WORK}/calls.txt"

cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
drives:
  - name: primary
    uuid: aaaaaaaa-0000-0000-0000-000000000001
    mountpoint: /mnt/primary
    active: true
samba:
  workgroup: WORKGROUP
  shares: []
sync_jobs:
  - name: first
    source: /mnt/primary/a/
    dest: /mnt/backup1/a/
    schedule: '*-*-* 03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
  - name: second
    source: /mnt/primary/b/
    dest: /mnt/backup1/b/
    schedule: '*-*-* 03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
  - name: elsewhere
    source: /mnt/primary/c/
    dest: /mnt/backup1/c/
    schedule: '*-*-* 07:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML

run_group() {
    : > "$SYSTEMCTL_CALLS"
    CONFIG_FILE="$TEST_CFG" \
    NASE_STAMP_DIR="$STAMPS" \
    NAS_LOG="${WORK}/nase.log" \
    REPO_ROOT="$REPO_ROOT" \
    bash "${REPO_ROOT}/modules/sync/run-group.sh" "$@" 2>>"${WORK}/nase.log"
}

# ── Only the group's own jobs run, in config order ────────────────────────────
rm -f "${STAMPS}/sync-runs.log"
assert_exit0 "group runs cleanly" run_group 03-00-00
CALLS=$(cat "$SYSTEMCTL_CALLS")
assert_eq "runs exactly the two jobs on that schedule, in config order" \
    "nase-sync-first.service
nase-sync-second.service" "$CALLS"
assert_not_contains "does not run a job from another schedule" \
    "elsewhere" "$CALLS"

# ── The ledger records what ran, and when ─────────────────────────────────────
LEDGER=$(cat "${STAMPS}/sync-runs.log")
assert_contains "ledger records job start" "first"$'\t'"start"  "$LEDGER"
assert_contains "ledger records job end"   "first"$'\t'"end"    "$LEDGER"
assert_eq "ledger has one start+end per job" "4" "$(wc -l < "${STAMPS}/sync-runs.log")"

# ── A failing job is recorded and does not stop the rest ──────────────────────
# The drives are already awake by then; abandoning the remaining jobs would
# waste the spin-up and leave backups silently stale.
rm -f "${STAMPS}/sync-runs.log"
FAIL_UNITS="nase-sync-first.service" run_group 03-00-00 && rc=0 || rc=$?
assert_eq "group exits non-zero when a job fails" "1" "$rc"
assert_contains "the job after the failure still ran" \
    "nase-sync-second.service" "$(cat "$SYSTEMCTL_CALLS")"
assert_contains "ledger marks the failure" "first"$'\t'"fail" \
    "$(cat "${STAMPS}/sync-runs.log")"

# ── An empty group is not an error ────────────────────────────────────────────
# A group timer can outlive the config edit that emptied it, until apply.sh runs.
assert_exit0 "empty group exits 0" run_group 99-99-99

# ── Attribution: which job was running when the drive woke ────────────────────
# Mirrors the awk selection in modules/drives/spin_sample.sh: the last job to
# have started at or before the wake, within the sampling window.
LSEL="${WORK}/ledger.txt"
printf '100\tjobA\tstart\n110\tjobA\tend\n200\tjobB\tstart\n290\tjobB\tend\n300\tjobC\tstart\n' > "$LSEL"
pick() {
    awk -F'\t' -v lo=$(( $1 - $2 )) -v hi="$1" \
        '$3=="start" && $1>=lo && $1<=hi {j=$2} END{if (j!="") print j}' "$LSEL"
}
assert_eq "attribution: names the job running at the wake"   "jobB" "$(pick 250 100)"
assert_eq "attribution: names the job that just finished"    "jobA" "$(pick 150 100)"
assert_eq "attribution: names the most recent start"         "jobC" "$(pick 305 100)"
assert_empty "attribution: silent when nothing ran in window"        "$(pick 1000 50)"
assert_empty "attribution: silent when window excludes the start"    "$(pick 250 10)"

# ── schedule_slug: shell and Python must agree ────────────────────────────────
# lib/config.sh names the units; main.py reads those names back to show a job's
# next trigger. If they ever disagreed the dashboard would silently show "—".
echo ""
echo "=== schedule_slug parity ==="
for s in '*-*-* 03:00:00' 'Mon *-*-* 04:00' 'daily' 'Mon,Thu *-*-* 02:30:00' '  *-*-* 05:00:00  '; do
    b=$(schedule_slug "$s")
    p=$(python3 -c "import re,sys; print(re.sub(r'[^a-z0-9]+','-',sys.argv[1].lower()).strip('-'))" "$s")
    assert_eq "slug parity: '${s}'" "$p" "$b"
done
assert_eq "slug of the live 03:00 schedule" "03-00-00" "$(schedule_slug '*-*-* 03:00:00')"

test_summary
