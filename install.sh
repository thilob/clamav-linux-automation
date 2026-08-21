#!/usr/bin/env bash
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_DIR="/etc/clamav-automation"
LIBEXEC_DIR="/usr/local/libexec/clamav-automation"
BACKUP_DIR="/var/backups/clamav-automation/$(date '+%Y%m%d-%H%M%S')"
CLAM_USER="clamav-auto"
CLAM_GROUP="clamav-auto"
CLAM_STATE_DIR="/var/lib/clamav-automation"
CLAM_DATABASE_DIR="$CLAM_STATE_DIR/database"
CONFIG_SOURCE=""
FORCE_INSTALL=0
UPGRADE=0
INSTALL_YARA_CORE=0
GENERATED_CONFIG=""
SMTP_OPTIONS_SET=0
SMTP_HOST=""
SMTP_PORT="587"
SMTP_SECURITY="starttls"
SMTP_USER=""
SMTP_PASSWORD=""
MAIL_FROM=""
MAIL_TO=""

cleanup() {
    [[ -z "$GENERATED_CONFIG" ]] || rm -f -- "$GENERATED_CONFIG"
}
trap cleanup EXIT

log() { printf '\n==> %s\n' "$*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ -r /etc/os-release ]] || die "/etc/os-release fehlt."

usage() {
    cat <<EOF
Aufruf: $0 [OPTIONEN]

  --force-install         nur inaktive Unit-Dateien/Templates bewusst übergehen
  --upgrade               vorhandene ClamAV-Automation sicher aktualisieren
  --install-yara-core     aktuelle YARA-Forge-Core-Regeln installieren
  --config-source DATEI   geprüfte Konfiguration der TUI/Automation verwenden
  --smtp-host WERT        SMTP-Server (Pflicht ohne --config-source)
  --smtp-port WERT        SMTP-Port (Standard: 587)
  --smtp-security WERT    starttls, ssl oder plain (Standard: starttls)
  --smtp-user WERT        SMTP-Benutzer; leer bedeutet keine Authentifizierung
  --smtp-password WERT    SMTP-Passwort
  --mail-from WERT        Mail-Absender (Pflicht ohne --config-source)
  --mail-to WERT          Mail-Empfänger (Pflicht ohne --config-source)
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --force-install)
            FORCE_INSTALL=1
            shift
            ;;
        --upgrade)
            UPGRADE=1
            shift
            ;;
        --install-yara-core)
            INSTALL_YARA_CORE=1
            shift
            ;;
        --config-source)
            (( $# >= 2 )) || die "Für --config-source fehlt eine Datei."
            CONFIG_SOURCE="$2"
            shift 2
            ;;
        --smtp-host|--smtp-port|--smtp-security|--smtp-user|--smtp-password|--mail-from|--mail-to)
            (( $# >= 2 )) || die "Für $1 fehlt ein Wert."
            option="$1"
            value="$2"
            case "$option" in
                --smtp-host) SMTP_HOST="$value" ;;
                --smtp-port) SMTP_PORT="$value" ;;
                --smtp-security) SMTP_SECURITY="$value" ;;
                --smtp-user) SMTP_USER="$value" ;;
                --smtp-password) SMTP_PASSWORD="$value" ;;
                --mail-from) MAIL_FROM="$value" ;;
                --mail-to) MAIL_TO="$value" ;;
            esac
            SMTP_OPTIONS_SET=1
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unbekannte Option: $1" ;;
    esac
done

if (( UPGRADE == 1 )); then
    (( FORCE_INSTALL == 0 && SMTP_OPTIONS_SET == 0 )) || \
        die "--upgrade darf nicht mit Installations- oder SMTP-Optionen kombiniert werden."
    [[ -z "$CONFIG_SOURCE" ]] || die "--upgrade darf nicht mit --config-source kombiniert werden."
    UPGRADE_ARGS=()
    (( INSTALL_YARA_CORE == 1 )) && UPGRADE_ARGS+=(--install-yara-core)
    exec "$PROJECT_DIR/scripts/upgrade-installation.sh" "${UPGRADE_ARGS[@]}"
fi

[[ -z "$CONFIG_SOURCE" || -r "$CONFIG_SOURCE" ]] || \
    die "Konfigurationsquelle ist nicht lesbar: $CONFIG_SOURCE"
if [[ -n "$CONFIG_SOURCE" ]]; then
    (( SMTP_OPTIONS_SET == 0 )) || die \
        "--config-source darf nicht mit einzelnen SMTP-Optionen kombiniert werden."
    bash -n "$CONFIG_SOURCE" || die "Konfigurationsquelle enthält ungültige Bash-Syntax."
fi

# Muss vor Paketinstallation, Benutzeranlage und allen anderen Änderungen laufen.
PREFLIGHT_ARGS=()
(( FORCE_INSTALL == 1 )) && PREFLIGHT_ARGS+=(--force-install)
"$PROJECT_DIR/scripts/preflight-check.sh" "${PREFLIGHT_ARGS[@]}"

if [[ -z "$CONFIG_SOURCE" && ! -e "$CONFIG_DIR/clamav-automation.conf" ]]; then
    [[ -n "$SMTP_HOST" ]] || die "Für die Erstinstallation fehlt --smtp-host."
    [[ -n "$MAIL_FROM" ]] || die "Für die Erstinstallation fehlt --mail-from."
    [[ -n "$MAIL_TO" ]] || die "Für die Erstinstallation fehlt --mail-to."
    if [[ ! "$SMTP_PORT" =~ ^[0-9]+$ ]] || (( SMTP_PORT < 1 || SMTP_PORT > 65535 )); then
        die "SMTP-Port muss zwischen 1 und 65535 liegen."
    fi
    [[ "$SMTP_SECURITY" =~ ^(starttls|ssl|plain)$ ]] || die "Ungültige SMTP-Sicherheit."
    [[ -z "$SMTP_USER" || -n "$SMTP_PASSWORD" ]] || die \
        "Bei gesetztem --smtp-user muss auch --smtp-password angegeben werden."

    # shellcheck source=./scripts/config-functions.sh
    source "$PROJECT_DIR/scripts/config-functions.sh"
    GENERATED_CONFIG="$(mktemp /tmp/clamav-automation-install.XXXXXX)"
    chmod 0600 "$GENERATED_CONFIG"
    config_copy_without_keys \
        "$PROJECT_DIR/config/clamav-automation.conf.example" "$GENERATED_CONFIG" \
        SMTP_HOST SMTP_PORT SMTP_SECURITY SMTP_USER SMTP_PASSWORD MAIL_FROM MAIL_TO
    {
        echo
        echo "# Während der Installation erfasste SMTP-Konfiguration"
    } >>"$GENERATED_CONFIG"
    config_append_scalar "$GENERATED_CONFIG" SMTP_HOST "$SMTP_HOST"
    config_append_scalar "$GENERATED_CONFIG" SMTP_PORT "$SMTP_PORT"
    config_append_scalar "$GENERATED_CONFIG" SMTP_SECURITY "$SMTP_SECURITY"
    config_append_scalar "$GENERATED_CONFIG" SMTP_USER "$SMTP_USER"
    config_append_scalar "$GENERATED_CONFIG" SMTP_PASSWORD "$SMTP_PASSWORD"
    config_append_scalar "$GENERATED_CONFIG" MAIL_FROM "$MAIL_FROM"
    config_append_scalar "$GENERATED_CONFIG" MAIL_TO "$MAIL_TO"
    CONFIG_SOURCE="$GENERATED_CONFIG"
fi
if [[ -n "$CONFIG_SOURCE" ]]; then
    bash -n "$CONFIG_SOURCE" || die "Die erzeugte Konfiguration enthält ungültige Bash-Syntax."
fi

# shellcheck source=/dev/null
source /etc/os-release
DISTRO_ID_RAW="${ID:-}"
[[ -n "$DISTRO_ID_RAW" ]] || die "/etc/os-release enthält keine Distributions-ID (ID)."
DISTRO_ID="${DISTRO_ID_RAW,,}"
DISTRO_LIKE="${ID_LIKE:-}"
VERSION_ID_VALUE="${VERSION_ID:-}"
VERSION_MAJOR="${VERSION_ID_VALUE%%.*}"

install_arch() {
    log "Installiere Pakete mit pacman"
    pacman -Syu --needed --noconfirm clamav python ca-certificates
}

install_debian() {
    log "Aktualisiere APT-Paketlisten"
    export DEBIAN_FRONTEND=noninteractive
    apt-get update

    log "Installiere ClamAV-Pakete mit APT"
    apt-get install -y --no-install-recommends \
        clamav clamav-daemon clamav-freshclam clamdscan python3 ca-certificates
}

enable_epel() {
    if rpm -q epel-release >/dev/null 2>&1; then
        return
    fi

    case "$DISTRO_ID" in
        rocky)
            dnf install -y dnf-plugins-core
            if [[ "$VERSION_MAJOR" =~ ^(9|10)$ ]]; then
                dnf config-manager --set-enabled crb 2>/dev/null || \
                    dnf config-manager --set-enabled CRB 2>/dev/null || true
            fi
            dnf install -y epel-release
            ;;
        rhel)
            if command -v subscription-manager >/dev/null 2>&1; then
                subscription-manager repos \
                    --enable="codeready-builder-for-rhel-${VERSION_MAJOR}-$(arch)-rpms" \
                    >/dev/null 2>&1 || true
            fi
            dnf install -y \
              "https://dl.fedoraproject.org/pub/epel/epel-release-latest-${VERSION_MAJOR}.noarch.rpm"
            ;;
        *)
            dnf install -y epel-release
            ;;
    esac
}

install_rhel_family() {
    log "Aktiviere EPEL"
    enable_epel

    log "Installiere ClamAV-Pakete"
    # EPEL splittet ClamAV in mehrere RPMs. Diese Menge deckt RHEL/Rocky 8/9/10
    # ab; anschließend werden die tatsächlich benötigten Binaries verifiziert.
    dnf install -y \
        clamav \
        clamav-update \
        clamav-server \
        clamav-server-systemd \
        python3 \
        ca-certificates \
        policycoreutils-python-utils || true

    # Fehlende Binaries über dnf provides gezielt nachinstallieren.
    for binary in clamd clamdscan freshclam clamonacc; do
        if ! command -v "$binary" >/dev/null 2>&1; then
            log "Suche RPM für fehlendes Binary: $binary"
            provider="$(dnf -q repoquery --whatprovides "*/$binary" --qf '%{name}' 2>/dev/null | head -n1 || true)"
            [[ -n "$provider" ]] || die "Kein Paket für $binary gefunden."
            dnf install -y "$provider"
        fi
    done
}

case "$DISTRO_ID" in
    debian)
        install_debian
        ;;
    arch|manjaro)
        install_arch
        ;;
    rocky|rhel)
        install_rhel_family
        ;;
    *)
        if [[ "$DISTRO_LIKE" == *arch* ]]; then
            install_arch
        elif [[ "$DISTRO_LIKE" == *rhel* || "$DISTRO_LIKE" == *fedora* ]]; then
            install_rhel_family
        else
            die "Nicht unterstützte Distribution: ${PRETTY_NAME:-$DISTRO_ID}"
        fi
        ;;
esac

if (( INSTALL_YARA_CORE == 1 )) && ! command -v yara >/dev/null 2>&1; then
    log "Installiere YARA für die Core-Regeln"
    case "$DISTRO_ID" in
        debian) apt-get install -y --no-install-recommends yara ;;
        arch|manjaro) pacman -S --needed --noconfirm yara ;;
        rocky|rhel) dnf install -y yara ;;
        *) die "YARA-Paketinstallation ist für diese Distribution nicht definiert." ;;
    esac
fi

for binary in clamd clamdscan freshclam clamonacc python3 systemctl journalctl flock sha256sum; do
    command -v "$binary" >/dev/null 2>&1 || die "Nach Installation fehlt: $binary"
done

log "Erkannte Version: $(clamscan --version 2>/dev/null || clamdscan --version)"

if ! getent group "$CLAM_GROUP" >/dev/null; then
    groupadd --system "$CLAM_GROUP"
fi

if ! id "$CLAM_USER" >/dev/null 2>&1; then
    useradd --system \
        --gid "$CLAM_GROUP" \
        --home-dir "$CLAM_STATE_DIR" \
        --no-create-home \
        --shell /usr/sbin/nologin \
        "$CLAM_USER"
fi

log "Sichere ggf. vorhandene Automation-Konfiguration"
mkdir -p "$BACKUP_DIR"
for path in "$CONFIG_DIR" \
            /etc/systemd/system/clamav-auto-clamd.service \
            /etc/systemd/system/clamav-auto-onaccess.service \
            /etc/systemd/system/clamav-auto-freshclam.service \
            /etc/systemd/system/clamav-auto-scan.service \
            /etc/systemd/system/clamav-auto-heartbeat.service; do
    [[ -e "$path" ]] && cp -a "$path" "$BACKUP_DIR/" || true
done

log "Installiere Dateien"
install -d -o root -g "$CLAM_GROUP" -m 0750 "$CONFIG_DIR"
install -d -m 0755 "$LIBEXEC_DIR"
install -d -o "$CLAM_USER" -g "$CLAM_GROUP" -m 0755 "$CLAM_STATE_DIR"
install -d -o "$CLAM_USER" -g "$CLAM_GROUP" -m 0755 "$CLAM_DATABASE_DIR"
install -d -o "$CLAM_USER" -g "$CLAM_GROUP" -m 0700 "$CLAM_STATE_DIR/tmp"
install -d -m 0750 /var/log/clamav-automation
install -d -o root -g root -m 0750 /var/lib/clamav-security/baselines
install -d -o root -g root -m 0750 /var/log/clamav-security
install -d -o root -g root -m 0750 /etc/clamav-security/yara

if [[ ! -e "$CONFIG_DIR/clamav-automation.conf" ]]; then
    install -m 0640 -o root -g "$CLAM_GROUP" \
        "${CONFIG_SOURCE:-$PROJECT_DIR/config/clamav-automation.conf.example}" \
        "$CONFIG_DIR/clamav-automation.conf"
    FIRST_INSTALL=1
else
    FIRST_INSTALL=0
    chown root:"$CLAM_GROUP" "$CONFIG_DIR/clamav-automation.conf"
    chmod 0640 "$CONFIG_DIR/clamav-automation.conf"
fi

install -m 0755 "$PROJECT_DIR/scripts/clamav-mail.py" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/clamav-virus-event.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/clamav-daily-scan.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/clamav-heartbeat.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/clamav-selftest.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/clamav-wait-for-clamd.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/security-audit.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/install-yara-core-rules.sh" "$LIBEXEC_DIR/"
install -m 0755 "$PROJECT_DIR/scripts/render-config.sh" "$LIBEXEC_DIR/"

for unit in "$PROJECT_DIR"/systemd/*.service; do
    install -m 0644 "$unit" /etc/systemd/system/
done

# Die Unit-Dateien referenzieren /usr/bin. Auf den unterstützten Distributionen
# liegen die ClamAV-Binaries derzeit dort. Falls nicht, werden lokale Symlinks
# gesetzt, ohne Paketdateien zu überschreiben.
for binary in clamd clamdscan freshclam clamonacc; do
    actual="$(command -v "$binary")"
    if [[ "$actual" != "/usr/bin/$binary" && ! -e "/usr/bin/$binary" ]]; then
        ln -s "$actual" "/usr/bin/$binary"
    fi
done

log "Deaktiviere konkurrierende Distributionsdienste, falls vorhanden"
for unit in \
    clamav-freshclam.service \
    clamav-freshclam-once.timer \
    clamav-daemon.service \
    clamav-daemon.socket \
    clamav-daemon.timer \
    clamav-clamonacc.service \
    clamd@scan.service \
    freshclam.service \
    freshclam.timer; do
    systemctl disable --now "$unit" >/dev/null 2>&1 || true
done

log "Erzeuge ClamAV- und Timer-Konfiguration"
"$LIBEXEC_DIR/render-config.sh"

# Vorhandene Distributionsdatenbanken dienen beim Upgrade als Startbestand. Das
# Distributionsverzeichnis selbst wird bewusst nicht mehr verändert.
shopt -s nullglob
existing_databases=(/var/lib/clamav/*.cvd /var/lib/clamav/*.cld /var/lib/clamav/freshclam.dat)
for database in "${existing_databases[@]}"; do
    [[ -e "$database" ]] || continue
    [[ -e "$CLAM_DATABASE_DIR/${database##*/}" ]] || cp -a "$database" "$CLAM_DATABASE_DIR/"
done
shopt -u nullglob
chown -R "$CLAM_USER:$CLAM_GROUP" "$CLAM_STATE_DIR"

if (( INSTALL_YARA_CORE == 1 )); then
    log "Lade und installiere YARA-Forge-Core-Regeln"
    "$LIBEXEC_DIR/install-yara-core-rules.sh"
fi

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    log "Konfiguriere SELinux-Grundeinstellung für Virenscanner"
    setsebool -P antivirus_can_scan_system 1 2>/dev/null || true
    if command -v semanage >/dev/null 2>&1 && [[ -d /var/lib/clamav ]]; then
        semanage fcontext -a -e /var/lib/clamav "$CLAM_STATE_DIR" 2>/dev/null || \
            semanage fcontext -m -e /var/lib/clamav "$CLAM_STATE_DIR"
    fi
    restorecon -RF "$CLAM_STATE_DIR" "$CONFIG_DIR" "$LIBEXEC_DIR" /var/log/clamav-automation \
        2>/dev/null || true
fi

log "Initiales Signaturupdate"
systemctl daemon-reload
if ! systemctl start clamav-auto-freshclam.service; then
    journalctl -u clamav-auto-freshclam.service -n 50 --no-pager || true
    die "Initiales freshclam-Update fehlgeschlagen."
fi

log "Aktiviere Dienste und Timer"
systemctl enable --now clamav-auto-clamd.service

log "Warte auf Betriebsbereitschaft von clamd"
if ! "$LIBEXEC_DIR/clamav-wait-for-clamd.sh" 180; then
    journalctl -u clamav-auto-clamd.service -n 80 --no-pager || true
    die "clamd wurde gestartet, ist aber nicht betriebsbereit."
fi
if ! systemctl is-active --quiet clamav-auto-clamd.service; then
    journalctl -u clamav-auto-clamd.service -n 80 --no-pager || true
    die "clamav-auto-clamd.service ist nach dem Start nicht aktiv."
fi

log "Aktiviere On-Access-Scanner und Timer"
systemctl enable --now clamav-auto-onaccess.service
systemctl enable --now clamav-auto-freshclam.timer
systemctl enable --now clamav-auto-scan.timer
systemctl enable --now clamav-auto-heartbeat.timer

# shellcheck source=/dev/null
source "$CONFIG_DIR/clamav-automation.conf"
if [[ "${SECURITY_AUDIT_ENABLED:-true}" =~ ^(yes|true|1|on)$ ]]; then
    if [[ "${SECURITY_AUDIT_DAILY_ENABLED:-true}" =~ ^(yes|true|1|on)$ ]]; then
        systemctl enable --now clamav-auto-security-daily.timer
    fi
    if [[ "${SECURITY_AUDIT_WEEKLY_ENABLED:-true}" =~ ^(yes|true|1|on)$ ]]; then
        systemctl enable --now clamav-auto-security-weekly.timer
    fi
fi

if ! systemctl is-active --quiet clamav-auto-onaccess.service; then
    journalctl -u clamav-auto-onaccess.service -n 80 --no-pager || true
    die "clamav-auto-onaccess.service ist nach dem Start nicht aktiv."
fi

echo
echo "============================================================"
echo " ClamAV Automation installiert"
echo "============================================================"
echo "Distribution : ${PRETTY_NAME:-$DISTRO_ID}"
echo "Konfiguration: $CONFIG_DIR/clamav-automation.conf"
echo "Selftest     : $LIBEXEC_DIR/clamav-selftest.sh"
echo "Backup       : $BACKUP_DIR"
echo
systemctl list-timers 'clamav-auto-*' --no-pager || true

if (( FIRST_INSTALL == 1 )); then
    echo
    echo "SMTP-Zugangsdaten wurden in die geschützte Konfiguration übernommen."
    echo "Jetzt testen:"
    echo "  sudo $LIBEXEC_DIR/clamav-selftest.sh"
fi
