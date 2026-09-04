#!/usr/bin/env bash
# tests/test-sync-setup.sh — unit tests for modules/sync/setup.sh unit generation.
# Does not require root; writes units to a temp dir and stubs out systemctl.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== modules/sync/setup.sh ==="
echo ""

# ── Workspace ──────────────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/nase-test-sync-setup.XXXXXX)
STUBS="${WORK}/stubs"
SYSTEMD_OUT="${WORK}/systemd"
TEST_CFG="${WORK}/config.yaml"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STUBS" "$SYSTEMD_OUT"

printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/systemctl"
chmod +x "${STUBS}/systemctl"

export PATH="${STUBS}:${PATH}"

# ── Helpers ────────────────────────────────────────────────────────────────────
run_setup() {
    CONFIG_FILE="$TEST_CFG" \
    SYSTEMD_DIR="$SYSTEMD_OUT" \
    bash "${REPO_ROOT}/modules/sync/setup.sh" 2>/dev/null
}

# Base config: two drives, one sync job, trash disabled.
write_base_cfg() {
    cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
drives:
  - name: primary
    uuid: aaaaaaaa-0000-0000-0000-000000000001
    mountpoint: /mnt/primary
    active: true
  - name: backup1
    uuid: bbbbbbbb-0000-0000-0000-000000000001
    mountpoint: /mnt/backup1
    active: true
samba:
  workgroup: WORKGROUP
  shares: []
sync_jobs:
  - name: photos
    source: /mnt/primary/photos/
    dest: /mnt/backup1/photos/
    schedule: '*-*-* 02:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash:
      enabled: false
      path: /mnt/backup1/.trash
      retention_days: 30
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
}

# ── Tests: service file ────────────────────────────────────────────────────────
write_base_cfg
run_setup
svc="${SYSTEMD_OUT}/nase-sync-photos.service"
tmr="${SYSTEMD_OUT}/nase-sync-group-02-00-00.timer"
grp="${SYSTEMD_OUT}/nase-sync-group-02-00-00.service"

assert_file_exists "service file created"        "$svc"
assert_file_exists "group timer created"         "$tmr"
assert_file_exists "group service created"       "$grp"
# The per-job timer is what phase 2 option C removes: nine of them firing at
# once is what made wake attribution meaningless.
assert_file_absent "no per-job timer"            "${SYSTEMD_OUT}/nase-sync-photos.timer"

svc_content=$(cat "$svc")
tmr_content=$(cat "$tmr")
grp_content=$(cat "$grp")

assert_contains "service Description contains job name" \
    "NASe sync: photos"          "$svc_content"
assert_contains "service ExecStart calls sync.sh" \
    "modules/sync/sync.sh photos" "$svc_content"
assert_contains "service Nice=10" \
    "Nice=10"                    "$svc_content"
assert_contains "service IOSchedulingClass" \
    "IOSchedulingClass=best-effort" "$svc_content"
assert_contains "service Type=oneshot" \
    "Type=oneshot"               "$svc_content"
assert_contains "service After= includes primary mount" \
    "mnt-primary.mount"          "$svc_content"
assert_contains "service After= includes backup mount" \
    "mnt-backup1.mount"          "$svc_content"

# ── Tests: group timer + group service ────────────────────────────────────────
assert_contains "group timer OnCalendar matches schedule" \
    "OnCalendar=*-*-* 02:00:00"  "$tmr_content"
assert_contains "group timer Persistent=true" \
    "Persistent=true"            "$tmr_content"
assert_contains "group timer Unit= references group service" \
    "Unit=nase-sync-group-02-00-00.service" "$tmr_content"
assert_contains "group service runs the group runner with its slug" \
    "modules/sync/run-group.sh 02-00-00" "$grp_content"
assert_contains "group service Type=oneshot" \
    "Type=oneshot"               "$grp_content"
assert_contains "group service After= includes primary mount" \
    "mnt-primary.mount"          "$grp_content"

# ── Tests: multiple jobs ───────────────────────────────────────────────────────
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
  - name: alpha
    source: /mnt/primary/alpha/
    dest: /mnt/backup1/alpha/
    schedule: '*-*-* 01:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash:
      enabled: false
      path: /mnt/backup1/.trash
      retention_days: 30
  - name: beta
    source: /mnt/primary/beta/
    dest: /mnt/backup1/beta/
    schedule: '*-*-* 03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash:
      enabled: false
      path: /mnt/backup1/.trash
      retention_days: 30
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
# Clean the output dir for a fresh run
rm -f "${SYSTEMD_OUT}"/nase-sync-*.{service,timer}
run_setup

assert_file_exists "multiple jobs: alpha service" "${SYSTEMD_OUT}/nase-sync-alpha.service"
assert_file_exists "multiple jobs: beta service"  "${SYSTEMD_OUT}/nase-sync-beta.service"
# Distinct schedules must stay in distinct groups — serialising jobs must not
# quietly move one of them to another time of day.
assert_file_exists "distinct schedules: 01:00 group" "${SYSTEMD_OUT}/nase-sync-group-01-00-00.timer"
assert_file_exists "distinct schedules: 03:00 group" "${SYSTEMD_OUT}/nase-sync-group-03-00-00.timer"

alpha_tmr=$(cat "${SYSTEMD_OUT}/nase-sync-group-01-00-00.timer")
beta_tmr=$(cat "${SYSTEMD_OUT}/nase-sync-group-03-00-00.timer")
assert_contains "alpha group schedule" "OnCalendar=*-*-* 01:00:00" "$alpha_tmr"
assert_contains "beta group schedule"  "OnCalendar=*-*-* 03:00:00" "$beta_tmr"

# ── Tests: jobs sharing a schedule collapse into ONE group ────────────────────
# This is the whole point of option C. Two jobs, one schedule, one timer.
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
  - name: one
    source: /mnt/primary/one/
    dest: /mnt/backup1/one/
    schedule: '*-*-* 03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
  - name: two
    source: /mnt/primary/two/
    dest: /mnt/backup1/two/
    schedule: '*-*-* 03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
rm -f "${SYSTEMD_OUT}"/nase-sync-*.service "${SYSTEMD_OUT}"/nase-sync-*.timer
run_setup

assert_file_exists "shared schedule: job one service" "${SYSTEMD_OUT}/nase-sync-one.service"
assert_file_exists "shared schedule: job two service" "${SYSTEMD_OUT}/nase-sync-two.service"
timer_count=$(find "$SYSTEMD_OUT" -name 'nase-sync-*.timer' | wc -l)
assert_eq "shared schedule: exactly one timer for both jobs" "1" "$timer_count"
assert_file_exists "shared schedule: the group timer" "${SYSTEMD_OUT}/nase-sync-group-03-00-00.timer"

# ── Tests: stale unit cleanup ─────────────────────────────────────────────────
# Pre-create units for a job that no longer exists in config.
touch "${SYSTEMD_OUT}/nase-sync-stale.service"
touch "${SYSTEMD_OUT}/nase-sync-stale.timer"
# ...and a group whose schedule nobody uses any more.
touch "${SYSTEMD_OUT}/nase-sync-group-09-09-09.service"
touch "${SYSTEMD_OUT}/nase-sync-group-09-09-09.timer"
# Run setup with config that has only "photos" (not "stale")
write_base_cfg
rm -f "${SYSTEMD_OUT}"/nase-sync-photos.{service,timer}
run_setup
assert_file_absent "stale service removed" "${SYSTEMD_OUT}/nase-sync-stale.service"
assert_file_absent "stale timer removed"   "${SYSTEMD_OUT}/nase-sync-stale.timer"
assert_file_absent "stale group service removed" "${SYSTEMD_OUT}/nase-sync-group-09-09-09.service"
assert_file_absent "stale group timer removed"   "${SYSTEMD_OUT}/nase-sync-group-09-09-09.timer"
assert_file_exists "current job kept"      "${SYSTEMD_OUT}/nase-sync-photos.service"
# The group cleanup must not mistake a live group for a deleted job: both share
# the nase-sync- prefix, and an over-eager sweep would delete the only timer.
assert_file_exists "live group survives job cleanup" "${SYSTEMD_OUT}/nase-sync-group-02-00-00.timer"

# ── Tests: slug collision is refused, not silently resolved ───────────────────
# Two distinct schedules that slugify the same would share one timer, and the
# last one written would win — a job would silently move to another time.
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
  - name: a
    source: /mnt/primary/a/
    dest: /mnt/backup1/a/
    schedule: '03:00:00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
  - name: b
    source: /mnt/primary/b/
    dest: /mnt/backup1/b/
    schedule: '03-00-00'
    on_failure: ignore
    force_sync_days: 7
    trash: {enabled: false, path: /mnt/backup1/.trash, retention_days: 30}
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
rm -f "${SYSTEMD_OUT}"/nase-sync-*.service "${SYSTEMD_OUT}"/nase-sync-*.timer
if run_setup 2>/dev/null; then
    echo "  FAIL  slug collision is rejected"
    TESTS_FAIL=$((TESTS_FAIL + 1))
else
    echo "  PASS  slug collision is rejected"
    TESTS_PASS=$((TESTS_PASS + 1))
fi

test_summary
