#!/usr/bin/env bash
set -uo pipefail

CONFIG="/etc/clamav-automation/clamav-automation.conf"
MAILER="/usr/local/libexec/clamav-automation/clamav-mail.py"

RED=$'\033[31m'
GREEN=$'\033[32m'
YELLOW=$'\033[33m'
RESET=$'\033[0m'

ok=0
warn=0
fail=0

pass() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; ((ok++)); }
warning() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*"; ((warn++)); }
failure() { printf '%s[FEHLER]%s %s\n' "$RED" "$RESET" "$*"; ((fail++)); }

echo "ClamAV Automation Selftest"
echo "=========================="
echo

for bin in clamd clamdscan freshclam clamonacc python3 systemctl journalctl; do
    if command -v "$bin" >/dev/null 2>&1; then
        pass "$bin gefunden: $(command -v "$bin")"
    else
        failure "$bin fehlt"
    fi
done

if [[ -f "$CONFIG" ]]; then
    pass "$CONFIG vorhanden"
    # shellcheck source=/dev/null
    source "$CONFIG"
else
    failure "$CONFIG fehlt"
fi

if [[ -S /run/clamav-automation/clamd.sock ]]; then
    pass "clamd-Socket vorhanden"
else
    failure "clamd-Socket fehlt"
fi

for unit in clamav-auto-clamd.service clamav-auto-onaccess.service; do
    if systemctl is-active --quiet "$unit"; then
        pass "$unit läuft"
    else
        failure "$unit läuft nicht"
    fi
done

for timer in clamav-auto-freshclam.timer clamav-auto-scan.timer clamav-auto-heartbeat.timer; do
    if systemctl is-active --quiet "$timer"; then
        pass "$timer aktiv"
    else
        failure "$timer nicht aktiv"
    fi
done

if [[ -d /proc/sys/fs/fanotify ]]; then
    pass "fanotify-Unterstützung im Kernel sichtbar"
else
    failure "/proc/sys/fs/fanotify fehlt; clamonacc kann so nicht funktionieren"
fi

if freshclam --version >/dev/null 2>&1; then
    pass "freshclam ausführbar"
else
    failure "freshclam nicht ausführbar"
fi

if clamdscan --config-file=/etc/clamav-automation/clamd.conf --ping=1 >/dev/null 2>&1; then
    pass "clamd antwortet"
else
    failure "clamd antwortet nicht auf clamdscan --ping=1"
fi

if command -v getenforce >/dev/null 2>&1; then
    state="$(getenforce)"
    echo
    echo "SELinux: $state"
    if [[ "$state" == "Enforcing" ]]; then
        if getsebool antivirus_can_scan_system 2>/dev/null | grep -q -- '--> on'; then
            pass "SELinux antivirus_can_scan_system=on"
        else
            warning "SELinux ist enforcing, antivirus_can_scan_system ist aber nicht aktiv"
        fi
    fi
fi

echo
read -r -p "SMTP-Testmail senden? [j/N] " answer
if [[ "$answer" =~ ^[jJyY]$ ]]; then
    if "$MAILER" --kind test; then
        pass "SMTP-Testmail wurde versendet"
    else
        failure "SMTP-Testmail fehlgeschlagen"
    fi
fi

echo
read -r -p "EICAR-Test mit On-Access-Scanner durchführen? [j/N] " answer
if [[ "$answer" =~ ^[jJyY]$ ]]; then
    # EICAR wird absichtlich erst hier zusammengesetzt, damit das Projektarchiv
    # selbst nicht von AV-Produkten als Testvirus markiert wird.
    testdir="/tmp/clamav-automation-eicar-test"
    mkdir -p "$testdir"
    testfile="$testdir/eicar.com"

    # Die Dollarzeichen gehören literal zur EICAR-Testsignatur.
    # shellcheck disable=SC2016
    printf '%s%s\n' \
      'X5O!P%@AP[4\PZX54(P^)7CC)7}$EICAR-STANDARD-ANTIVIRUS-TEST-FILE!' \
      '$H+H*' >"$testfile" 2>/dev/null || true

    sleep 3

    if journalctl --since "1 minute ago" --no-pager \
        -u clamav-auto-clamd.service -u clamav-auto-onaccess.service 2>/dev/null \
        | grep -qi 'Eicar\|FOUND'; then
        pass "EICAR wurde im Journal erkannt"
    else
        warning "Keine EICAR-Erkennung im Journal gefunden. Pfad ggf. nicht in ONACCESS_PATHS."
    fi

    rm -rf "$testdir" 2>/dev/null || true
fi

echo
echo "Ergebnis: $ok OK, $warn Warnungen, $fail Fehler"
(( fail == 0 ))
