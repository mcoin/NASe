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
tmr="${SYSTEMD_OUT}/nase-sync-photos.timer"

assert_file_exists "service file created"  "$svc"
assert_file_exists "timer file created"    "$tmr"

svc_content=$(cat "$svc")
tmr_content=$(cat "$tmr")

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

# ── Tests: timer file ─────────────────────────────────────────────────────────
assert_contains "timer OnCalendar matches schedule" \
    "OnCalendar=*-*-* 02:00:00"  "$tmr_content"
assert_contains "timer Persistent=true" \
    "Persistent=true"            "$tmr_content"
assert_contains "timer Unit= references service" \
    "Unit=nase-sync-photos.service" "$tmr_content"
assert_contains "timer Description contains job name" \
    "NASe sync timer: photos"    "$tmr_content"

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
assert_file_exists "multiple jobs: alpha timer"   "${SYSTEMD_OUT}/nase-sync-alpha.timer"
assert_file_exists "multiple jobs: beta service"  "${SYSTEMD_OUT}/nase-sync-beta.service"
assert_file_exists "multiple jobs: beta timer"    "${SYSTEMD_OUT}/nase-sync-beta.timer"

alpha_tmr=$(cat "${SYSTEMD_OUT}/nase-sync-alpha.timer")
beta_tmr=$(cat "${SYSTEMD_OUT}/nase-sync-beta.timer")
assert_contains "alpha timer schedule" "OnCalendar=*-*-* 01:00:00" "$alpha_tmr"
assert_contains "beta timer schedule"  "OnCalendar=*-*-* 03:00:00" "$beta_tmr"

# ── Tests: stale unit cleanup ─────────────────────────────────────────────────
# Pre-create units for a job that no longer exists in config.
touch "${SYSTEMD_OUT}/nase-sync-stale.service"
touch "${SYSTEMD_OUT}/nase-sync-stale.timer"
# Run setup with config that has only "photos" (not "stale")
write_base_cfg
rm -f "${SYSTEMD_OUT}"/nase-sync-photos.{service,timer}
run_setup
assert_file_absent "stale service removed" "${SYSTEMD_OUT}/nase-sync-stale.service"
assert_file_absent "stale timer removed"   "${SYSTEMD_OUT}/nase-sync-stale.timer"
assert_file_exists "current job kept"      "${SYSTEMD_OUT}/nase-sync-photos.service"

test_summary
