#!/usr/bin/env bash
set -Eeuo pipefail

[[ $EUID -eq 0 ]] || { echo "Bitte als root ausführen." >&2; exit 1; }

KEEP_CONFIG=1
REMOVE_PACKAGES=0

usage() {
    cat <<EOF
Aufruf: $0 [--purge-config] [--remove-packages]

  --purge-config     /etc/clamav-automation ebenfalls löschen
  --remove-packages  ClamAV-Pakete deinstallieren
EOF
}

for arg in "$@"; do
    case "$arg" in
        --purge-config) KEEP_CONFIG=0 ;;
        --remove-packages) REMOVE_PACKAGES=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannte Option: $arg" >&2; usage; exit 2 ;;
    esac
done

for unit in \
    clamav-auto-onaccess.service \
    clamav-auto-clamd.service \
    clamav-auto-freshclam.timer \
    clamav-auto-scan.timer \
    clamav-auto-heartbeat.timer \
    clamav-auto-security-daily.timer \
    clamav-auto-security-weekly.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

rm -f \
    /etc/systemd/system/clamav-auto-clamd.service \
    /etc/systemd/system/clamav-auto-onaccess.service \
    /etc/systemd/system/clamav-auto-freshclam.service \
    /etc/systemd/system/clamav-auto-freshclam.timer \
    /etc/systemd/system/clamav-auto-scan.service \
    /etc/systemd/system/clamav-auto-scan.timer \
    /etc/systemd/system/clamav-auto-heartbeat.service \
    /etc/systemd/system/clamav-auto-heartbeat.timer \
    /etc/systemd/system/clamav-auto-security-daily.service \
    /etc/systemd/system/clamav-auto-security-daily.timer \
    /etc/systemd/system/clamav-auto-security-weekly.service \
    /etc/systemd/system/clamav-auto-security-weekly.timer

rm -rf /usr/local/libexec/clamav-automation

if (( KEEP_CONFIG == 0 )); then
    rm -rf /etc/clamav-automation /etc/clamav-security \
        /var/log/clamav-automation /var/log/clamav-security \
        /var/lib/clamav-security /var/lib/clamav-automation
else
    echo "Konfiguration bleibt erhalten: /etc/clamav-automation"
fi

systemctl daemon-reload
systemctl reset-failed >/dev/null 2>&1 || true

if (( REMOVE_PACKAGES == 1 )); then
    if [[ -r /etc/os-release ]]; then
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID,,}" in
            arch|manjaro)
                pacman -Rns --noconfirm clamav || true
                ;;
            rocky|rhel)
                dnf remove -y 'clamav*' || true
                ;;
        esac
    fi
fi

echo "ClamAV Automation wurde entfernt."
