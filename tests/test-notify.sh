#!/usr/bin/env bash
# tests/test-notify.sh — unit tests for modules/sync/notify.sh dispatch logic.
# Does not require root; stubs curl, msmtp, sendmail, mail.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "${REPO_ROOT}/tests/lib.sh"

echo "=== modules/sync/notify.sh ==="
echo ""

# ── Workspace ──────────────────────────────────────────────────────────────────
WORK=$(mktemp -d /tmp/nase-test-notify.XXXXXX)
STUBS="${WORK}/stubs"
TEST_CFG="${WORK}/config.yaml"
export STUB_LOG="${WORK}/stub_calls"
trap 'rm -rf "$WORK"' EXIT

mkdir -p "$STUBS"

# curl: record invocation, exit 0
cat > "${STUBS}/curl" <<'EOF'
#!/usr/bin/env bash
echo "curl $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "${STUBS}/curl"

# msmtp: consume stdin, record invocation, exit 0
cat > "${STUBS}/msmtp" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "msmtp $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "${STUBS}/msmtp"

# sendmail: consume stdin, record invocation, exit 0
cat > "${STUBS}/sendmail" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "sendmail $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "${STUBS}/sendmail"

# mail: consume stdin, record invocation, exit 0
cat > "${STUBS}/mail" <<'EOF'
#!/usr/bin/env bash
cat > /dev/null
echo "mail $*" >> "$STUB_LOG"
exit 0
EOF
chmod +x "${STUBS}/mail"

export PATH="${STUBS}:${PATH}"

# ── Helpers ────────────────────────────────────────────────────────────────────
run_notify() {
    CONFIG_FILE="$TEST_CFG" \
    bash "${REPO_ROOT}/modules/sync/notify.sh" "Test subject" "Test body" 2>/dev/null
}

reset_log() { rm -f "$STUB_LOG"; }

stub_was_called() { grep -q "$1" "$STUB_LOG" 2>/dev/null; }

# ── Tests ──────────────────────────────────────────────────────────────────────

# 1. method=none: exits 0, nothing called
cat > "$TEST_CFG" <<'YAML'
notifications:
  method: none
YAML
reset_log
assert_exit0 "method=none: exits 0" run_notify
assert_not_contains "method=none: curl not called" \
    "curl" "$(cat "$STUB_LOG" 2>/dev/null || true)"

# 2. method=unknown: exits 0, nothing called
cat > "$TEST_CFG" <<'YAML'
notifications:
  method: carrier-pigeon
YAML
reset_log
assert_exit0 "method=unknown: exits 0" run_notify
assert_not_contains "method=unknown: curl not called" \
    "curl" "$(cat "$STUB_LOG" 2>/dev/null || true)"

# 3. method=webhook, WEBHOOK_URL empty: exits 0, curl not called
cat > "$TEST_CFG" <<'YAML'
notifications:
  method: webhook
YAML
reset_log
assert_exit0 "method=webhook, no URL: exits 0" \
    bash -c "CONFIG_FILE='$TEST_CFG' WEBHOOK_URL='' \
        bash '${REPO_ROOT}/modules/sync/notify.sh' 'subj' 'body' 2>/dev/null"
assert_not_contains "method=webhook, no URL: curl not called" \
    "curl" "$(cat "$STUB_LOG" 2>/dev/null || true)"

# 4. method=webhook, URL set: curl called with the URL
cat > "$TEST_CFG" <<'YAML'
notifications:
  method: webhook
YAML
reset_log
CONFIG_FILE="$TEST_CFG" \
WEBHOOK_URL="https://hooks.example.com/abc123" \
    bash "${REPO_ROOT}/modules/sync/notify.sh" "subj" "body" 2>/dev/null
assert_contains "method=webhook, URL set: curl called with URL" \
    "https://hooks.example.com/abc123" "$(cat "$STUB_LOG")"
assert_contains "method=webhook: POST method passed" \
    "POST" "$(cat "$STUB_LOG")"

# 5. method=email, SMTP_HOST empty: falls back to sendmail
cat > "$TEST_CFG" <<'YAML'
notifications:
  method: email
  email: admin@example.com
YAML
reset_log
CONFIG_FILE="$TEST_CFG" \
SMTP_HOST="" \
    bash "${REPO_ROOT}/modules/sync/notify.sh" "subj" "body" 2>/dev/null
assert_contains "method=email, no SMTP_HOST: sendmail called" \
    "sendmail" "$(cat "$STUB_LOG")"
assert_not_contains "method=email, no SMTP_HOST: msmtp not called" \
    "msmtp" "$(cat "$STUB_LOG")"

# 6. method=email, SMTP_HOST set, msmtp available: msmtp called
reset_log
CONFIG_FILE="$TEST_CFG" \
SMTP_HOST="smtp.example.com" \
SMTP_USER="user@example.com" \
SMTP_PASSWORD="secret" \
    bash "${REPO_ROOT}/modules/sync/notify.sh" "subj" "body" 2>/dev/null
assert_contains "method=email, SMTP set: msmtp called" \
    "msmtp" "$(cat "$STUB_LOG")"
assert_contains "method=email: recipient passed to msmtp" \
    "admin@example.com" "$(cat "$STUB_LOG")"

test_summary
