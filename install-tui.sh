#!/usr/bin/env bash
# Geführte Installation in einer an IBM AS/400 angelehnten Terminaloberfläche.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
TMP_CONFIG=""
FORCE_INSTALL=0

cleanup() {
    [[ -z "$TMP_CONFIG" ]] || rm -f -- "$TMP_CONFIG"
}
trap cleanup EXIT

die() { echo "FEHLER: $*" >&2; exit 1; }
[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ -t 0 && -t 1 ]] || die "Die TUI benötigt ein interaktives Terminal."

if (( $# > 1 )); then
    die "Aufruf: $0 [--force-install]"
elif (( $# == 1 )); then
    [[ "$1" == "--force-install" ]] || die "Unbekannte Option: $1"
    FORCE_INSTALL=1
fi

# Die Konfliktprüfung erfolgt vor der Erfassung vertraulicher Eingaben.
PREFLIGHT_ARGS=()
(( FORCE_INSTALL == 1 )) && PREFLIGHT_ARGS+=(--force-install)
"$PROJECT_DIR/scripts/preflight-check.sh" "${PREFLIGHT_ARGS[@]}"

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

shell_quote() { printf '%q' "$1"; }

append_scalar() {
    printf '%s=%s\n' "$1" "$(shell_quote "$2")" >>"$TMP_CONFIG"
}

append_array() {
    local name="$1" raw="$2" item
    printf '%s=(\n' "$name" >>"$TMP_CONFIG"
    IFS=':' read -r -a items <<<"$raw"
    for item in "${items[@]}"; do
        [[ -n "$item" ]] && printf '    %s\n' "$(shell_quote "$item")" >>"$TMP_CONFIG"
    done
    printf ')\n' >>"$TMP_CONFIG"
}

dmsg "HAUPTMENÜ" \
"5770-CLM  ClamAV Automation

Mit F12 bzw. <Abbrechen> kann die Installation jederzeit beendet werden.
Alle Angaben werden vor der Installation nochmals angezeigt."

while :; do
    SMTP_HOST="$(inputbox "SMTP-PARAMETER" "SMTP-Server (FQDN oder IP-Adresse)" "smtp.example.org")" || exit 1
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
    MAIL_FROM="$(inputbox "MAIL-ADRESSEN" "Absenderadresse" "clamav@example.org")" || exit 1
    require_nonempty "MAIL_FROM" "$MAIL_FROM" && break
done
while :; do
    MAIL_TO="$(inputbox "MAIL-ADRESSEN" "Empfängeradresse(n)" "admin@example.org")" || exit 1
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

TMP_CONFIG="$(mktemp /tmp/clamav-automation-tui.XXXXXX)"
chmod 0600 "$TMP_CONFIG"
cp "$PROJECT_DIR/config/clamav-automation.conf.example" "$TMP_CONFIG"
{
    echo
    echo "# Von install-tui.sh erfasste Werte"
} >>"$TMP_CONFIG"
append_scalar SMTP_HOST "$SMTP_HOST"
append_scalar SMTP_PORT "$SMTP_PORT"
append_scalar SMTP_SECURITY "$SMTP_SECURITY"
append_scalar SMTP_USER "$SMTP_USER"
append_scalar SMTP_PASSWORD "$SMTP_PASSWORD"
append_scalar MAIL_FROM "$MAIL_FROM"
append_scalar MAIL_TO "$MAIL_TO"
append_array DAILY_SCAN_PATHS "$DAILY_SCAN_PATHS"
append_array ONACCESS_PATHS "$ONACCESS_PATHS"
append_scalar ONACCESS_PREVENTION "$ONACCESS_PREVENTION"
append_scalar CLAMD_MAX_FILE_SIZE "$CLAMD_MAX_FILE_SIZE"
append_scalar CLAMD_MAX_SCAN_SIZE "$CLAMD_MAX_SCAN_SIZE"
append_scalar CLAMD_MAX_RECURSION "$CLAMD_MAX_RECURSION"
append_scalar CLAMD_MAX_FILES "$CLAMD_MAX_FILES"
append_scalar DETECT_PUA "$DETECT_PUA"
append_scalar FRESHCLAM_CALENDAR "$FRESHCLAM_CALENDAR"
append_scalar DAILY_SCAN_CALENDAR "$DAILY_SCAN_CALENDAR"
append_scalar HEARTBEAT_CALENDAR "$HEARTBEAT_CALENDAR"
append_scalar FRESHCLAM_RANDOM_DELAY "$FRESHCLAM_RANDOM_DELAY"
append_scalar DAILY_SCAN_RANDOM_DELAY "$DAILY_SCAN_RANDOM_DELAY"
append_scalar HEARTBEAT_RANDOM_DELAY "$HEARTBEAT_RANDOM_DELAY"
append_scalar SCAN_LOG_RETENTION_DAYS "$SCAN_LOG_RETENTION_DAYS"
append_scalar HEARTBEAT_JOURNAL_SINCE "$HEARTBEAT_JOURNAL_SINCE"

SUMMARY="SMTP:        $SMTP_HOST:$SMTP_PORT ($SMTP_SECURITY)
Absender:     $MAIL_FROM
Empfänger:    $MAIL_TO
Daily Scan:   $DAILY_SCAN_PATHS
On-Access:    $ONACCESS_PATHS
Prevention:   $ONACCESS_PREVENTION
PUA:          $DETECT_PUA
Scanzeit:     $DAILY_SCAN_CALENDAR
Heartbeat:    $HEARTBEAT_CALENDAR

Das SMTP-Passwort wird aus Sicherheitsgründen nicht angezeigt."

dialog --clear --backtitle "$BACKTITLE" --title "INSTALLATION BESTÄTIGEN" \
    --yes-label "Installieren" --no-label "Abbrechen" --yesno "$SUMMARY" 20 78 || exit 1
clear
INSTALL_ARGS=(--config-source "$TMP_CONFIG")
(( FORCE_INSTALL == 1 )) && INSTALL_ARGS+=(--force-install)
"$PROJECT_DIR/install.sh" "${INSTALL_ARGS[@]}"
