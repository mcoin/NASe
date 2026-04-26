#!/usr/bin/env bash
# tests/test-config.sh — unit tests for lib/config.sh.
# Requires: yq (mikefarah v4) on PATH.
# No root needed; no drives needed.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== lib/config.sh ==="
echo ""

command -v yq &>/dev/null || { echo "SKIP: yq not found"; exit 0; }

# ── Create a minimal test config ─────────────────────────────────────────────
TEST_CONFIG=$(mktemp --suffix=.yaml)
trap 'rm -f "$TEST_CONFIG"' EXIT

cat > "$TEST_CONFIG" <<'YAML'
nas:
  hostname: testhost

drives:
  - name: primary
    active: true
    uuid: "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"
    mountpoint: /mnt/primary
    role: main
    filesystem: ext4
    spindown_min: 60
    smart_check: true
    owner: nase
    read_only: false

  - name: backup
    active: false
    uuid: "11111111-2222-3333-4444-555555555555"
    mountpoint: /mnt/backup
    role: backup
    filesystem: ext4
    spindown_min: 60
    smart_check: true
    read_only: true

sync_jobs:
  - name: test-job
    source: /mnt/primary/data/
    dest: /mnt/backup/data/
    schedule: "*-*-* 03:00:00"
    rsync_flags: "--archive --delete"
    on_failure: notify
    force_sync_days: 14
    trash:
      enabled: true
      path: /mnt/backup/.trash
      retention_days: 30

services:
  filebrowser:
    enabled: false
    port: 8080
    root: /mnt
    username: nase
    base_url: ""

tailscale:
  enabled: false
  advertise_exit_node: false
  advertise_routes: ""

samba:
  workgroup: TESTGROUP
  users:
    - nase
  shares: []

notifications:
  method: none
YAML

export CONFIG_FILE="$TEST_CONFIG"
source "${REPO_ROOT}/lib/config.sh"

# ── config_get ────────────────────────────────────────────────────────────────
assert_eq "config_get: string"          "testhost"    "$(config_get '.nas.hostname')"
assert_eq "config_get: integer"         "8080"        "$(config_get '.services.filebrowser.port')"
assert_eq "config_get: boolean true"    "true"        "$(config_get '.drives[0].active')"
assert_eq "config_get: boolean false"   "false"       "$(config_get '.services.filebrowser.enabled')"
assert_eq "config_get: absent key"      ""            "$(config_get '.does.not.exist')"
assert_eq "config_get: empty string"    ""            "$(config_get '.tailscale.advertise_routes')"
assert_eq "config_get: nested"          "30"          "$(config_get '.sync_jobs[0].trash.retention_days')"

# ── config_len ────────────────────────────────────────────────────────────────
assert_eq "config_len: drives"          "2"           "$(config_len '.drives')"
assert_eq "config_len: sync_jobs"       "1"           "$(config_len '.sync_jobs')"
assert_eq "config_len: empty array"     "0"           "$(config_len '.samba.shares')"
assert_eq "config_len: absent key"      "0"           "$(config_len '.does_not_exist')"

# ── config_idx ────────────────────────────────────────────────────────────────
assert_eq "config_idx: first drive name"     "primary"   "$(config_idx '.drives' '0' '.name')"
assert_eq "config_idx: second drive name"    "backup"    "$(config_idx '.drives' '1' '.name')"
assert_eq "config_idx: drive uuid"           "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee" \
                                                         "$(config_idx '.drives' '0' '.uuid')"
assert_eq "config_idx: inactive drive"       "false"     "$(config_idx '.drives' '1' '.active')"
assert_eq "config_idx: nested field"         "true"      "$(config_idx '.sync_jobs' '0' '.trash.enabled')"
assert_eq "config_idx: numeric nested"       "14"        "$(config_idx '.sync_jobs' '0' '.force_sync_days')"
assert_eq "config_idx: absent nested"        ""          "$(config_idx '.drives' '0' '.does_not_exist')"

# ── config_bool ───────────────────────────────────────────────────────────────
assert_exit0 "config_bool: true value"  config_bool '.drives[0].active'
assert_exit1 "config_bool: false value" config_bool '.services.filebrowser.enabled'
assert_exit1 "config_bool: absent key"  config_bool '.does.not.exist'

test_summary
