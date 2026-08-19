#!/usr/bin/env bash
# Geführte Installation in einer an IBM AS/400 angelehnten Terminaloberfläche.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_CONFIG=""
FORCE_INSTALL=0
UPGRADE=0

cleanup() {
    [[ -z "$TMP_CONFIG" ]] || rm -f -- "$TMP_CONFIG"
}
trap cleanup EXIT

die() { echo "FEHLER: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ -t 0 && -t 1 ]] || die "Die TUI benötigt ein interaktives Terminal."

if (( $# > 1 )); then
    die "Aufruf: $0 [--force-install|--upgrade]"
elif (( $# == 1 )); then
    case "$1" in
        --force-install) FORCE_INSTALL=1 ;;
        --upgrade) UPGRADE=1 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
fi

if (( UPGRADE == 1 )); then
    exec "$PROJECT_DIR/install.sh" --upgrade
fi

# Die Konfliktprüfung erfolgt vor der Erfassung vertraulicher Eingaben.
PREFLIGHT_ARGS=()
(( FORCE_INSTALL == 1 )) && PREFLIGHT_ARGS+=(--force-install)
"$PROJECT_DIR/scripts/preflight-check.sh" "${PREFLIGHT_ARGS[@]}"

# shellcheck source=scripts/config-functions.sh
source "$PROJECT_DIR/scripts/config-functions.sh"

command -v dialog >/dev/null 2>&1 || die \
    "Das Programm 'dialog' wird für die TUI benötigt (Arch: pacman -S dialog, RHEL/Rocky: dnf install dialog)."

export DIALOGRC="${DIALOGRC:-$PROJECT_DIR/config/dialogrc-as400}"
BACKTITLE="CLAMAV AUTOMATION - SYSTEM INSTALLATION"

dmsg() {
    dialog --clear --backtitle "$BACKTITLE" --title "$1" --msgbox "$2" 12 76
}

inputbox() {
    local title="$1" prompt="$2" default="$3"
    dialog --clear --backtitle "$BACKTITLE" --title "$title" \
        --inputbox "$prompt" 12 76 "$default" 3>&1 1>&2 2>&3
}

passwordbox() {
    dialog --clear --backtitle "$BACKTITLE" --title "$1" \
        --insecure --passwordbox "$2" 12 76 3>&1 1>&2 2>&3
}

menu_choice() {
    local title="$1" prompt="$2" default="$3"
    shift 3
    dialog --clear --backtitle "$BACKTITLE" --title "$title" \
        --default-item "$default" --menu "$prompt" 16 76 6 "$@" 3>&1 1>&2 2>&3
}

require_nonempty() {
    [[ -n "$2" ]] || { dmsg "EINGABEFEHLER" "$1 darf nicht leer sein."; return 1; }
}

require_uint() {
    [[ "$2" =~ ^[0-9]+$ ]] || { dmsg "EINGABEFEHLER" "$1 muss eine nichtnegative ganze Zahl sein."; return 1; }
}

dmsg "HAUPTMENÜ" \
"5770-CLM  ClamAV Automation

Mit F12 bzw. <Abbrechen> kann die Installation jederzeit beendet werden.
Alle Angaben werden vor der Installation nochmals angezeigt."

while :; do
    SMTP_HOST="$(inputbox "SMTP-PARAMETER" "SMTP-Server (FQDN oder IP-Adresse)" "")" || exit 1
    require_nonempty "SMTP_HOST" "$SMTP_HOST" && break
done
while :; do
    SMTP_PORT="$(inputbox "SMTP-PARAMETER" "SMTP-Port" "587")" || exit 1
    require_uint "SMTP_PORT" "$SMTP_PORT" && (( SMTP_PORT >= 1 && SMTP_PORT <= 65535 )) && break
    dmsg "EINGABEFEHLER" "SMTP_PORT muss zwischen 1 und 65535 liegen."
done
SMTP_SECURITY="$(menu_choice "SMTP-PARAMETER" "Transportverschlüsselung auswählen" "starttls" \
    starttls "STARTTLS (typisch Port 587)" ssl "SMTPS (typisch Port 465)" plain "Unverschlüsselt")" || exit 1
SMTP_USER="$(inputbox "SMTP-ANMELDUNG" "SMTP-Benutzer (leer = keine Authentifizierung)" "")" || exit 1
SMTP_PASSWORD="$(passwordbox "SMTP-ANMELDUNG" "SMTP-Passwort (wird nicht angezeigt)")" || exit 1
while :; do
    MAIL_FROM="$(inputbox "MAIL-ADRESSEN" "Absenderadresse" "")" || exit 1
    require_nonempty "MAIL_FROM" "$MAIL_FROM" && break
done
while :; do
    MAIL_TO="$(inputbox "MAIL-ADRESSEN" "Empfängeradresse(n)" "")" || exit 1
    require_nonempty "MAIL_TO" "$MAIL_TO" && break
done

DAILY_SCAN_PATHS="$(inputbox "SCANBEREICHE" \
    "Tägliche Scanpfade, durch Doppelpunkt getrennt" "/home:/root:/etc:/usr/local:/opt:/srv:/var/www:/tmp:/var/tmp")" || exit 1
ONACCESS_PATHS="$(inputbox "SCANBEREICHE" \
    "On-Access-Pfade, durch Doppelpunkt getrennt. '/' ist nicht zulässig." "/home:/tmp:/var/tmp")" || exit 1
IFS=':' read -r -a onaccess_items <<<"$ONACCESS_PATHS"
for path in "${onaccess_items[@]}"; do
    [[ "$path" != "/" ]] || die "'/' darf nicht als On-Access-Pfad verwendet werden."
done
ONACCESS_PREVENTION="$(menu_choice "SCANOPTIONEN" "Zugriff auf erkannte Schadsoftware verhindern?" "no" \
    no "Nur erkennen und melden" yes "Zugriff verhindern")" || exit 1
DETECT_PUA="$(menu_choice "SCANOPTIONEN" "Potenziell unerwünschte Anwendungen erkennen?" "yes" \
    yes "PUA-Erkennung aktiv" no "PUA-Erkennung inaktiv")" || exit 1

CLAMD_MAX_FILE_SIZE="$(inputbox "SCANLIMITS" "Maximale Dateigröße" "100M")" || exit 1
CLAMD_MAX_SCAN_SIZE="$(inputbox "SCANLIMITS" "Maximale Scanmenge" "500M")" || exit 1
CLAMD_MAX_RECURSION="$(inputbox "SCANLIMITS" "Maximale Rekursionstiefe" "20")" || exit 1
CLAMD_MAX_FILES="$(inputbox "SCANLIMITS" "Maximale Dateianzahl" "20000")" || exit 1
require_uint "CLAMD_MAX_RECURSION" "$CLAMD_MAX_RECURSION" || exit 1
require_uint "CLAMD_MAX_FILES" "$CLAMD_MAX_FILES" || exit 1

FRESHCLAM_CALENDAR="$(inputbox "ZEITPLANUNG" "Signaturupdate (systemd OnCalendar)" "*-*-* 00,06,12,18:15:00")" || exit 1
DAILY_SCAN_CALENDAR="$(inputbox "ZEITPLANUNG" "Täglicher Scan (systemd OnCalendar)" "*-*-* 02:30:00")" || exit 1
HEARTBEAT_CALENDAR="$(inputbox "ZEITPLANUNG" "Heartbeat (systemd OnCalendar)" "*-*-* 06:45:00")" || exit 1
FRESHCLAM_RANDOM_DELAY="$(inputbox "ZEITPLANUNG" "Zufallsverzögerung Signaturupdate" "10m")" || exit 1
DAILY_SCAN_RANDOM_DELAY="$(inputbox "ZEITPLANUNG" "Zufallsverzögerung Scan" "30m")" || exit 1
HEARTBEAT_RANDOM_DELAY="$(inputbox "ZEITPLANUNG" "Zufallsverzögerung Heartbeat" "15m")" || exit 1
SCAN_LOG_RETENTION_DAYS="$(inputbox "PROTOKOLLIERUNG" "Aufbewahrung der Scanprotokolle in Tagen" "30")" || exit 1
require_uint "SCAN_LOG_RETENTION_DAYS" "$SCAN_LOG_RETENTION_DAYS" || exit 1
HEARTBEAT_JOURNAL_SINCE="$(inputbox "PROTOKOLLIERUNG" "Journal-Zeitraum für den Heartbeat" "24 hours ago")" || exit 1

SECURITY_AUDIT_ENABLED="$(menu_choice "SECURITY AUDIT" "Ergänzenden Security Audit aktivieren?" "true" \
    true "Audit aktivieren" false "Audit deaktivieren")" || exit 1
SECURITY_AUDIT_DAILY_ENABLED="$(menu_choice "SECURITY AUDIT" "Täglichen Audit-Timer aktivieren?" "true" \
    true "Daily aktivieren" false "Daily deaktivieren")" || exit 1
SECURITY_AUDIT_WEEKLY_ENABLED="$(menu_choice "SECURITY AUDIT" "Wöchentlichen Intensiv-Audit aktivieren?" "true" \
    true "Weekly aktivieren" false "Weekly deaktivieren")" || exit 1
SECURITY_CHECK_NETWORK="$(menu_choice "SECURITY AUDIT" "Listening Sockets mit Baseline vergleichen?" "false" \
    false "Netzwerkprüfung deaktiviert" true "Netzwerkprüfung aktiviert")" || exit 1
SECURITY_CHECK_YARA="$(menu_choice "SECURITY AUDIT" "Optionale lokale YARA-Regeln verwenden?" "true" \
    true "YARA verwenden, falls installiert" false "YARA deaktivieren")" || exit 1
if dialog --clear --backtitle "$BACKTITLE" --title "YARA CORE-REGELN" \
    --yes-label "Ja" --no-label "Nein" --defaultno \
    --yesno "Aktuelle YARA-Forge-Core-Regeln herunterladen, prüfen und installieren?\n\nQuelle: github.com/YARAHQ/yara-forge\nZiel: /etc/clamav-security/yara/yara-forge-core.yar" 14 76; then
    INSTALL_YARA_CORE=1
else
    INSTALL_YARA_CORE=0
fi
SECURITY_AUDIT_DAILY_CALENDAR="$(inputbox "AUDIT-ZEITPLAN" "Täglicher Security Audit (systemd OnCalendar)" "*-*-* 03:40:00")" || exit 1
SECURITY_AUDIT_WEEKLY_CALENDAR="$(inputbox "AUDIT-ZEITPLAN" "Wöchentlicher Security Audit (systemd OnCalendar)" "Sun *-*-* 04:30:00")" || exit 1

TMP_CONFIG="$(mktemp /tmp/clamav-automation-tui.XXXXXX)"
chmod 0600 "$TMP_CONFIG"
config_copy_without_keys \
    "$PROJECT_DIR/config/clamav-automation.conf.example" "$TMP_CONFIG" \
    SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO \
    DAILY_SCAN_PATHS ONACCESS_PATHS ONACCESS_PREVENTION CLAMD_MAX_FILE_SIZE \
    CLAMD_MAX_SCAN_SIZE CLAMD_MAX_RECURSION CLAMD_MAX_FILES DETECT_PUA \
    FRESHCLAM_CALENDAR DAILY_SCAN_CALENDAR HEARTBEAT_CALENDAR \
    FRESHCLAM_RANDOM_DELAY DAILY_SCAN_RANDOM_DELAY HEARTBEAT_RANDOM_DELAY \
    SCAN_LOG_RETENTION_DAYS HEARTBEAT_JOURNAL_SINCE \
    SECURITY_AUDIT_ENABLED SECURITY_AUDIT_DAILY_ENABLED SECURITY_AUDIT_WEEKLY_ENABLED \
    SECURITY_CHECK_NETWORK SECURITY_CHECK_YARA SECURITY_AUDIT_DAILY_CALENDAR \
    SECURITY_AUDIT_WEEKLY_CALENDAR
{
    echo
    echo "# Von install-tui.sh erfasste Werte"
} >>"$TMP_CONFIG"
config_append_scalar "$TMP_CONFIG" SMTP_HOST "$SMTP_HOST"
config_append_scalar "$TMP_CONFIG" SMTP_PORT "$SMTP_PORT"
config_append_scalar "$TMP_CONFIG" SMTP_SECURITY "$SMTP_SECURITY"
config_append_scalar "$TMP_CONFIG" SMTP_USER "$SMTP_USER"
config_append_scalar "$TMP_CONFIG" SMTP_PASSWORD "$SMTP_PASSWORD"
config_append_scalar "$TMP_CONFIG" MAIL_FROM "$MAIL_FROM"
config_append_scalar "$TMP_CONFIG" MAIL_TO "$MAIL_TO"
config_append_array "$TMP_CONFIG" DAILY_SCAN_PATHS "$DAILY_SCAN_PATHS"
config_append_array "$TMP_CONFIG" ONACCESS_PATHS "$ONACCESS_PATHS"
config_append_scalar "$TMP_CONFIG" ONACCESS_PREVENTION "$ONACCESS_PREVENTION"
config_append_scalar "$TMP_CONFIG" CLAMD_MAX_FILE_SIZE "$CLAMD_MAX_FILE_SIZE"
config_append_scalar "$TMP_CONFIG" CLAMD_MAX_SCAN_SIZE "$CLAMD_MAX_SCAN_SIZE"
config_append_scalar "$TMP_CONFIG" CLAMD_MAX_RECURSION "$CLAMD_MAX_RECURSION"
config_append_scalar "$TMP_CONFIG" CLAMD_MAX_FILES "$CLAMD_MAX_FILES"
config_append_scalar "$TMP_CONFIG" DETECT_PUA "$DETECT_PUA"
config_append_scalar "$TMP_CONFIG" FRESHCLAM_CALENDAR "$FRESHCLAM_CALENDAR"
config_append_scalar "$TMP_CONFIG" DAILY_SCAN_CALENDAR "$DAILY_SCAN_CALENDAR"
config_append_scalar "$TMP_CONFIG" HEARTBEAT_CALENDAR "$HEARTBEAT_CALENDAR"
config_append_scalar "$TMP_CONFIG" FRESHCLAM_RANDOM_DELAY "$FRESHCLAM_RANDOM_DELAY"
config_append_scalar "$TMP_CONFIG" DAILY_SCAN_RANDOM_DELAY "$DAILY_SCAN_RANDOM_DELAY"
config_append_scalar "$TMP_CONFIG" HEARTBEAT_RANDOM_DELAY "$HEARTBEAT_RANDOM_DELAY"
config_append_scalar "$TMP_CONFIG" SCAN_LOG_RETENTION_DAYS "$SCAN_LOG_RETENTION_DAYS"
config_append_scalar "$TMP_CONFIG" HEARTBEAT_JOURNAL_SINCE "$HEARTBEAT_JOURNAL_SINCE"
config_append_scalar "$TMP_CONFIG" SECURITY_AUDIT_ENABLED "$SECURITY_AUDIT_ENABLED"
config_append_scalar "$TMP_CONFIG" SECURITY_AUDIT_DAILY_ENABLED "$SECURITY_AUDIT_DAILY_ENABLED"
config_append_scalar "$TMP_CONFIG" SECURITY_AUDIT_WEEKLY_ENABLED "$SECURITY_AUDIT_WEEKLY_ENABLED"
config_append_scalar "$TMP_CONFIG" SECURITY_CHECK_NETWORK "$SECURITY_CHECK_NETWORK"
config_append_scalar "$TMP_CONFIG" SECURITY_CHECK_YARA "$SECURITY_CHECK_YARA"
config_append_scalar "$TMP_CONFIG" SECURITY_AUDIT_DAILY_CALENDAR "$SECURITY_AUDIT_DAILY_CALENDAR"
config_append_scalar "$TMP_CONFIG" SECURITY_AUDIT_WEEKLY_CALENDAR "$SECURITY_AUDIT_WEEKLY_CALENDAR"

SUMMARY="SMTP:        $SMTP_HOST:$SMTP_PORT ($SMTP_SECURITY)
Absender:     $MAIL_FROM
Empfänger:    $MAIL_TO
Daily Scan:   $DAILY_SCAN_PATHS
On-Access:    $ONACCESS_PATHS
Prevention:   $ONACCESS_PREVENTION
PUA:          $DETECT_PUA
Scanzeit:     $DAILY_SCAN_CALENDAR
Heartbeat:    $HEARTBEAT_CALENDAR
Audit Daily:  $SECURITY_AUDIT_ENABLED / $SECURITY_AUDIT_DAILY_CALENDAR
Audit Weekly: $SECURITY_AUDIT_WEEKLY_ENABLED / $SECURITY_AUDIT_WEEKLY_CALENDAR
YARA Core:    $([[ $INSTALL_YARA_CORE -eq 1 ]] && echo installieren || echo nicht installieren)

Das SMTP-Passwort wird aus Sicherheitsgründen nicht angezeigt."

dialog --clear --backtitle "$BACKTITLE" --title "INSTALLATION BESTÄTIGEN" \
    --yes-label "Installieren" --no-label "Abbrechen" --yesno "$SUMMARY" 20 78 || exit 1
clear
INSTALL_ARGS=(--config-source "$TMP_CONFIG")
(( FORCE_INSTALL == 1 )) && INSTALL_ARGS+=(--force-install)
(( INSTALL_YARA_CORE == 1 )) && INSTALL_ARGS+=(--install-yara-core)
"$PROJECT_DIR/install.sh" "${INSTALL_ARGS[@]}"
