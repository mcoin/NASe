#!/usr/bin/env bash
# tests/test-samba.sh — unit tests for modules/samba/setup.sh smb.conf generation.
# Does not require root; stubs out systemctl, testparm, smbpasswd, useradd.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== modules/samba/setup.sh ==="
echo ""

# ── Workspace ──────────────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/nase-test-samba.XXXXXX)
STUBS="${WORK}/stubs"
SAMBA_OUT="${WORK}/smb.conf"
TEST_CFG="${WORK}/config.yaml"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STUBS"

# Stub commands that require root or running daemons.
for cmd in systemctl smbpasswd useradd; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/${cmd}"
    chmod +x "${STUBS}/${cmd}"
done
# testparm validates smb.conf — always approve in tests.
printf '#!/usr/bin/env bash\nexit 0\n' > "${STUBS}/testparm"
chmod +x "${STUBS}/testparm"
# id returns 1 so the "create user" branch is exercised without root.
printf '#!/usr/bin/env bash\nexit 1\n' > "${STUBS}/id"
chmod +x "${STUBS}/id"

export PATH="${STUBS}:${PATH}"

# ── Helpers ────────────────────────────────────────────────────────────────────
run_setup() {
    CONFIG_FILE="$TEST_CFG" \
    SAMBA_CONF="$SAMBA_OUT" \
    bash "${REPO_ROOT}/modules/samba/setup.sh" 2>/dev/null
}

# ── Tests ──────────────────────────────────────────────────────────────────────

# 1. Workgroup substitution
cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
samba:
  workgroup: MYGROUP
  shares: []
drives: []
sync_jobs: []
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
run_setup
out=$(cat "$SAMBA_OUT")
assert_contains "workgroup substituted in [global]" "workgroup = MYGROUP" "$out"
assert_not_contains "placeholder removed"           "__WORKGROUP__"        "$out"

# 2. Single share: all fields rendered correctly
cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
samba:
  workgroup: WORKGROUP
  shares:
    - name: Data
      path: /mnt/primary/data
      read_only: false
      valid_users: nase
drives: []
sync_jobs: []
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
run_setup
out=$(cat "$SAMBA_OUT")
assert_contains "share section header"  "[Data]"                  "$out"
assert_contains "share path"            "path = /mnt/primary/data" "$out"
assert_contains "read only = no"        "read only = no"           "$out"
assert_contains "valid users"           "valid users = nase"       "$out"
assert_contains "browseable = yes"      "browseable = yes"         "$out"

# 3. read_only: true → "yes"
cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
samba:
  workgroup: WORKGROUP
  shares:
    - name: Backup
      path: /mnt/backup1/data
      read_only: true
      valid_users: nase
drives: []
sync_jobs: []
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
run_setup
out=$(cat "$SAMBA_OUT")
assert_contains "read_only true → read only = yes" "read only = yes" "$out"

# 4. Multiple shares: all sections present
cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
samba:
  workgroup: WORKGROUP
  shares:
    - name: Photos
      path: /mnt/primary/photos
      read_only: false
      valid_users: nase
    - name: Archive
      path: /mnt/backup1/archive
      read_only: true
      valid_users: nase
drives: []
sync_jobs: []
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
run_setup
out=$(cat "$SAMBA_OUT")
assert_contains "first share [Photos]"             "[Photos]"                   "$out"
assert_contains "first share path"                 "path = /mnt/primary/photos" "$out"
assert_contains "second share [Archive]"           "[Archive]"                  "$out"
assert_contains "second share path"                "path = /mnt/backup1/archive" "$out"
assert_contains "second share read only = yes"     "read only = yes"            "$out"

# 5. No shares: global section present, no share blocks
cat > "$TEST_CFG" <<'YAML'
nas:
  hostname: test-nas
samba:
  workgroup: WORKGROUP
  shares: []
drives: []
sync_jobs: []
services: {}
tailscale:
  enabled: false
notifications:
  method: none
YAML
run_setup
out=$(cat "$SAMBA_OUT")
assert_contains     "global section present" "[global]"  "$out"
assert_not_contains "no share path lines"    "path = "   "$out"

test_summary
