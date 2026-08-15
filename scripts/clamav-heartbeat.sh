#!/usr/bin/env bash
set -uo pipefail

CONFIG="/etc/clamav-automation/clamav-automation.conf"
MAILER="/usr/local/libexec/clamav-automation/clamav-mail.py"

# shellcheck source=/dev/null
source "$CONFIG"

units=(
    clamav-auto-clamd.service
    clamav-auto-onaccess.service
    clamav-auto-freshclam.service
    clamav-auto-freshclam.timer
    clamav-auto-scan.service
    clamav-auto-scan.timer
    clamav-auto-heartbeat.timer
    clamav-auto-security-daily.timer
    clamav-auto-security-weekly.timer
)

DETAILS="$(
    {
        echo "=== Service-Status ==="
        for unit in "${units[@]}"; do
            printf '%-38s %s\n' "$unit" "$(systemctl is-active "$unit" 2>/dev/null || true)"
        done

        echo
        echo "=== ClamAV-Version ==="
        clamd --version 2>&1 || true

        echo
        echo "=== clamd-Verbindung ==="
        if clamdscan --config-file=/etc/clamav-automation/clamd.conf --ping=1 >/dev/null 2>&1; then
            echo "OK: clamd antwortet über /run/clamav-automation/clamd.sock"
        else
            echo "FEHLER: clamd antwortet nicht über /run/clamav-automation/clamd.sock"
        fi

        echo
        echo "=== Signaturdateien ==="
        ls -lh /var/lib/clamav 2>&1 || true

        echo
        echo "=== Journal: ${HEARTBEAT_JOURNAL_SINCE:-24 hours ago} ==="
        journalctl \
            --since "${HEARTBEAT_JOURNAL_SINCE:-24 hours ago}" \
            --no-pager \
            -u clamav-auto-clamd.service \
            -u clamav-auto-onaccess.service \
            -u clamav-auto-freshclam.service \
            -u clamav-auto-scan.service \
            2>&1 || true
    }
)"

"$MAILER" --kind heartbeat --details "$DETAILS"
