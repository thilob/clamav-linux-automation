#!/usr/bin/env bash
# Generiert clamd.conf und systemd-Timer-Units aus der zentralen Konfiguration.
set -Eeuo pipefail

CONFIG="/etc/clamav-automation/clamav-automation.conf"
CLAMD_CONF="/etc/clamav-automation/clamd.conf"

# shellcheck source=/dev/null
source "$CONFIG"

mkdir -p /etc/clamav-automation

bool_value() {
    case "${1,,}" in
        yes|true|1|on) printf 'yes' ;;
        *) printf 'no' ;;
    esac
}

cat >"$CLAMD_CONF" <<EOF
DatabaseDirectory /var/lib/clamav
TemporaryDirectory /var/lib/clamav/tmp
LocalSocket /run/clamav-automation/clamd.sock
LocalSocketMode 0660
FixStaleSocket yes
User clamav-auto
LogSyslog yes
LogTime yes
PidFile /run/clamav-automation/clamd.pid

ScanArchive yes
ScanPE yes
ScanELF yes
ScanOLE2 yes
ScanPDF yes
ScanSWF yes
ScanXMLDOCS yes
ScanHWP3 yes

DetectPUA $(bool_value "${DETECT_PUA:-yes}")
MaxFileSize ${CLAMD_MAX_FILE_SIZE:-100M}
MaxScanSize ${CLAMD_MAX_SCAN_SIZE:-500M}
MaxRecursion ${CLAMD_MAX_RECURSION:-20}
MaxFiles ${CLAMD_MAX_FILES:-20000}

VirusEvent /usr/local/libexec/clamav-automation/clamav-virus-event.sh

OnAccessExcludeUname clamav-auto
OnAccessPrevention $(bool_value "${ONACCESS_PREVENTION:-no}")
EOF

count=0
for path in "${ONACCESS_PATHS[@]}"; do
    [[ "$path" == "/" ]] && {
        echo "FEHLER: '/' darf nicht als ONACCESS_PATHS verwendet werden." >&2
        exit 2
    }
    if [[ -d "$path" ]]; then
        printf 'OnAccessIncludePath %s\n' "$path" >>"$CLAMD_CONF"
        ((count+=1))
    else
        echo "Hinweis: On-Access-Pfad existiert nicht und wird übersprungen: $path" >&2
    fi
done

(( count > 0 )) || {
    echo "FEHLER: Kein gültiger ONACCESS_PATHS-Pfad vorhanden." >&2
    exit 2
}

cat >/etc/clamav-automation/freshclam.conf <<'EOF'
DatabaseDirectory /var/lib/clamav
DatabaseOwner clamav-auto
DNSDatabaseInfo current.cvd.clamav.net
DatabaseMirror database.clamav.net
LogSyslog yes
LogTime yes
NotifyClamd /etc/clamav-automation/clamd.conf
EOF

cat >/etc/systemd/system/clamav-auto-freshclam.timer <<EOF
[Unit]
Description=ClamAV signatures update schedule

[Timer]
OnCalendar=${FRESHCLAM_CALENDAR:-*-*-* 00,06,12,18:15:00}
Persistent=true
RandomizedDelaySec=${FRESHCLAM_RANDOM_DELAY:-10m}

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/clamav-auto-scan.timer <<EOF
[Unit]
Description=Daily ClamAV filesystem scan schedule

[Timer]
OnCalendar=${DAILY_SCAN_CALENDAR:-*-*-* 02:30:00}
Persistent=true
RandomizedDelaySec=${DAILY_SCAN_RANDOM_DELAY:-30m}

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/clamav-auto-heartbeat.timer <<EOF
[Unit]
Description=Daily ClamAV heartbeat schedule

[Timer]
OnCalendar=${HEARTBEAT_CALENDAR:-*-*-* 06:45:00}
Persistent=true
RandomizedDelaySec=${HEARTBEAT_RANDOM_DELAY:-15m}

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/clamav-auto-security-daily.timer <<EOF
[Unit]
Description=Daily ClamAV security audit schedule

[Timer]
OnCalendar=${SECURITY_AUDIT_DAILY_CALENDAR:-*-*-* 03:40:00}
Persistent=true
RandomizedDelaySec=${SECURITY_AUDIT_DAILY_RANDOM_DELAY:-30m}

[Install]
WantedBy=timers.target
EOF

cat >/etc/systemd/system/clamav-auto-security-weekly.timer <<EOF
[Unit]
Description=Weekly ClamAV security audit schedule

[Timer]
OnCalendar=${SECURITY_AUDIT_WEEKLY_CALENDAR:-Sun *-*-* 04:30:00}
Persistent=true
RandomizedDelaySec=${SECURITY_AUDIT_WEEKLY_RANDOM_DELAY:-60m}

[Install]
WantedBy=timers.target
EOF

chown root:clamav-auto "$CLAMD_CONF"
chmod 0640 "$CLAMD_CONF"
chmod 0644 /etc/clamav-automation/freshclam.conf
chmod 0644 /etc/systemd/system/clamav-auto-security-daily.timer \
    /etc/systemd/system/clamav-auto-security-weekly.timer
systemctl daemon-reload
