#!/usr/bin/env bash
# Aktualisiert ausschließlich eine vorhandene Installation dieses Projekts.
set -Eeuo pipefail

PROJECT_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
CONFIG_DIR="/etc/clamav-automation"
LIBEXEC_DIR="/usr/local/libexec/clamav-automation"
STATE_DIR="/var/lib/clamav-automation"
DATABASE_DIR="$STATE_DIR/database"
BACKUP_DIR="/var/backups/clamav-automation/$(date '+%Y%m%d-%H%M%S')-upgrade"
CLAM_USER="clamav-auto"
CLAM_GROUP="clamav-auto"
FRESHCLAM_OK=1
INSTALL_YARA_CORE=0

log() { printf '\n==> %s\n' "$*"; }
die() { echo "FEHLER: $*" >&2; exit 1; }

if (( $# > 1 )); then
    die "Aufruf: $0 [--install-yara-core]"
elif (( $# == 1 )); then
    [[ "$1" == "--install-yara-core" ]] || die "Unbekannte Option: $1"
    INSTALL_YARA_CORE=1
fi

[[ $EUID -eq 0 ]] || die "Bitte als root ausführen."
[[ -r "$CONFIG_DIR/clamav-automation.conf" ]] || \
    die "Keine vorhandene Projektkonfiguration gefunden: $CONFIG_DIR/clamav-automation.conf"
[[ -f /etc/systemd/system/clamav-auto-clamd.service ]] || \
    die "Keine vorhandene ClamAV-Automation erkannt. Verwende für eine Neuinstallation install.sh."
id "$CLAM_USER" >/dev/null 2>&1 || die "Projektbenutzer fehlt: $CLAM_USER"
getent group "$CLAM_GROUP" >/dev/null || die "Projektgruppe fehlt: $CLAM_GROUP"
for binary in clamd clamdscan freshclam clamonacc systemctl journalctl; do
    command -v "$binary" >/dev/null 2>&1 || die "Erforderliches Programm fehlt: $binary"
done

log "Sichere vorhandene Projektdateien"
install -d -m 0700 "$BACKUP_DIR"
cp -a "$CONFIG_DIR" "$BACKUP_DIR/"
for path in /etc/systemd/system/clamav-auto-* "$LIBEXEC_DIR"; do
    [[ -e "$path" ]] && cp -a "$path" "$BACKUP_DIR/" || true
done

log "Migriere die Signaturdatenbank"
install -d -o "$CLAM_USER" -g "$CLAM_GROUP" -m 0755 "$STATE_DIR" "$DATABASE_DIR"
install -d -o "$CLAM_USER" -g "$CLAM_GROUP" -m 0700 "$STATE_DIR/tmp"
shopt -s nullglob
existing_databases=(/var/lib/clamav/*.cvd /var/lib/clamav/*.cld /var/lib/clamav/freshclam.dat)
for database in "${existing_databases[@]}"; do
    [[ -e "$DATABASE_DIR/${database##*/}" ]] || cp -a "$database" "$DATABASE_DIR/"
done
shopt -u nullglob
chown -R "$CLAM_USER:$CLAM_GROUP" "$STATE_DIR"

log "Aktualisiere Skripte und systemd-Units"
install -d -m 0755 "$LIBEXEC_DIR"
for script in "$PROJECT_DIR"/scripts/*; do
    [[ -f "$script" ]] && install -m 0755 "$script" "$LIBEXEC_DIR/"
done
for unit in "$PROJECT_DIR"/systemd/*.service; do
    install -m 0644 "$unit" /etc/systemd/system/
done
"$LIBEXEC_DIR/render-config.sh"

if (( INSTALL_YARA_CORE == 1 )); then
    if ! command -v yara >/dev/null 2>&1; then
        [[ -r /etc/os-release ]] || die "/etc/os-release fehlt."
        # shellcheck source=/dev/null
        source /etc/os-release
        case "${ID,,}" in
            debian) apt-get update; apt-get install -y --no-install-recommends yara ;;
            arch|manjaro) pacman -S --needed --noconfirm yara ;;
            rocky|rhel) dnf install -y yara ;;
            *) die "YARA-Paketinstallation ist für diese Distribution nicht definiert." ;;
        esac
    fi
    log "Lade und installiere YARA-Forge-Core-Regeln"
    "$LIBEXEC_DIR/install-yara-core-rules.sh"
fi

if command -v getenforce >/dev/null 2>&1 && [[ "$(getenforce)" != "Disabled" ]]; then
    restorecon -RF "$STATE_DIR" "$CONFIG_DIR" "$LIBEXEC_DIR" 2>/dev/null || true
fi

log "Aktualisiere Virensignaturen"
if ! systemctl start clamav-auto-freshclam.service; then
    FRESHCLAM_OK=0
    echo "WARNUNG: Freshclam ist fehlgeschlagen; die Scanner werden trotzdem wiederhergestellt." >&2
    journalctl -u clamav-auto-freshclam.service -n 60 --no-pager >&2 || true
fi

log "Starte Scanner mit der aktualisierten Konfiguration neu"
systemctl stop clamav-auto-onaccess.service >/dev/null 2>&1 || true
systemctl restart clamav-auto-clamd.service
if ! "$LIBEXEC_DIR/clamav-wait-for-clamd.sh" 180; then
    journalctl -u clamav-auto-clamd.service -n 80 --no-pager >&2 || true
    die "clamd ist nach dem Upgrade nicht betriebsbereit. Backup: $BACKUP_DIR"
fi
systemctl restart clamav-auto-onaccess.service

systemctl enable --now clamav-auto-freshclam.timer clamav-auto-scan.timer \
    clamav-auto-heartbeat.timer

echo
echo "Upgrade abgeschlossen. Backup: $BACKUP_DIR"
systemctl --no-pager --full status clamav-auto-clamd.service \
    clamav-auto-onaccess.service clamav-auto-freshclam.timer \
    clamav-auto-heartbeat.timer || true

if (( FRESHCLAM_OK == 0 )); then
    die "Scanner laufen, aber das Signaturupdate ist fehlgeschlagen. Siehe Journalausgabe oben."
fi
