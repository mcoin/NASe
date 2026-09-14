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

# ── The flat-map cache (backlog #24, item 3) ─────────────────────────────────
# The whole file is parsed once by a single `yq -o=props` and the accessors are
# string lookups after that. These pin the properties that make the swap safe.

# Defaults. yq's `a // b` yields b when a is null *or false* — not merely when
# absent — and that is reproduced rather than corrected, because this was a
# behaviour-preserving change. The one place it bites is tracked separately.
assert_eq "default used for an absent key" "fallback" \
    "$(config_get '.does.not.exist // "fallback"')"
assert_eq "default not used when a value is present" "testhost" \
    "$(config_get '.nas.hostname // "fallback"')"
assert_eq "an unquoted numeric default works" "10" \
    "$(config_get '.does.not.exist // 10')"
assert_eq "a default containing spaces survives" "Sat *-*-* 03:00:00" \
    "$(config_get '.does.not.exist // "Sat *-*-* 03:00:00"')"
assert_eq "yq semantics: false falls back to the default" "true" \
    "$(config_get '.services.filebrowser.enabled // "true"')"
assert_eq "but without a default, false is false" "false" \
    "$(config_get '.services.filebrowser.enabled')"

# Values that a naive "key = value" split would mangle.
assert_eq "a value containing a space is not truncated" "*-*-* 03:00:00" \
    "$(config_get '.sync_jobs[0].schedule')"

# The cache is keyed on the file's identity, so a config edited mid-run is
# picked up rather than served stale from the first parse.
CFG_COPY=$(mktemp --suffix=.yaml)
printf 'nas:\n  hostname: first\n' > "$CFG_COPY"
( CONFIG_FILE="$CFG_COPY"
  source "${REPO_ROOT}/lib/config.sh"
  assert_eq "reads the file it was pointed at" "first" "$(config_get '.nas.hostname')"
  sleep 1
  printf 'nas:\n  hostname: second\n' > "$CFG_COPY"
  assert_eq "notices the file changing underneath it" "second" "$(config_get '.nas.hostname')" )

rm -f "$CFG_COPY"

# The cache has to be built in the *caller's* shell, not lazily on first use.
# Essentially every call site is `x=$(config_get ...)`, which runs in a
# subshell: a cache populated there dies with it, so a lazily built one would
# be rebuilt on every call and end up slower than the per-field yq it replaced.
# Asserting it is already populated here, before any accessor has been called
# in this shell, is what pins that down.
assert_exit0 "the cache is populated at source time" \
    test "${#_CONFIG_CACHE[@]}" -gt 0
assert_eq "a subshell inherits the populated cache" "testhost" \
    "$(printf '%s' "${_CONFIG_CACHE[nas.hostname]}")"

test_summary
