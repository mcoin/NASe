#!/usr/bin/env bash
# modules/sync/notify.sh
# Send a notification (email or webhook) on sync failure or SMART alerts.
# Usage: notify.sh "<subject>" "<body>"
set -euo pipefail

REPO_ROOT="${REPO_ROOT:-$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)}"
source "${REPO_ROOT}/lib/log.sh"
source "${REPO_ROOT}/lib/config.sh"

SUBJECT="${1:-NASe alert}"
BODY="${2:-No details provided.}"

METHOD=$(config_get '.notifications.method')

case "$METHOD" in
    email)
        RECIPIENT=$(config_get '.notifications.email')
        SMTP_HOST="${SMTP_HOST:-}"
        SMTP_PORT="${SMTP_PORT:-587}"
        SMTP_USER="${SMTP_USER:-}"
        SMTP_PASSWORD="${SMTP_PASSWORD:-}"
        SMTP_FROM="${SMTP_FROM:-nase@localhost}"

        if [[ -z "$SMTP_HOST" ]]; then
            log_warn "SMTP_HOST not set — falling back to local sendmail."
            echo -e "Subject: ${SUBJECT}\n\n${BODY}" | sendmail "$RECIPIENT" || true
            exit 0
        fi

        # Use msmtp if available; otherwise use mailutils mail command
        if command -v msmtp &>/dev/null; then
            cat > /tmp/nase-msmtprc.$$ <<EOF
defaults
tls on
tls_starttls on

account nase
host ${SMTP_HOST}
port ${SMTP_PORT}
auth on
user ${SMTP_USER}
password ${SMTP_PASSWORD}
from ${SMTP_FROM}
logfile /var/log/msmtp.log

account default : nase
EOF
            trap 'rm -f /tmp/nase-msmtprc.$$' EXIT
            printf 'To: %s\nFrom: %s\nSubject: %s\n\n%s\n' \
                "$RECIPIENT" "$SMTP_FROM" "$SUBJECT" "$BODY" \
                | msmtp --file="/tmp/nase-msmtprc.$$" "$RECIPIENT"
        else
            printf '%s\n' "$BODY" | mail -s "$SUBJECT" "$RECIPIENT"
        fi
        log_info "Email notification sent to ${RECIPIENT}."
        ;;

    webhook)
        WEBHOOK_URL="${WEBHOOK_URL:-}"
        [[ -n "$WEBHOOK_URL" ]] || { log_warn "WEBHOOK_URL not set — skipping notification."; exit 0; }

        payload=$(printf '{"text": "%s\n%s"}' \
            "$(echo "$SUBJECT" | sed 's/"/\\"/g')" \
            "$(echo "$BODY"    | sed 's/"/\\"/g')")

        curl -s -X POST \
            -H "Content-Type: application/json" \
            -d "$payload" \
            "$WEBHOOK_URL" \
            || log_warn "Webhook delivery failed."
        log_info "Webhook notification sent."
        ;;

    none|"")
        log_info "Notifications disabled (method=none)."
        ;;

    *)
        log_warn "Unknown notification method '${METHOD}' — skipping."
        ;;
esac
