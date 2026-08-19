#!/usr/bin/env bash
# Unterscheidet eine vorhandene Installation von verwaisten/inaktiven Unit-Dateien.
set -Eeuo pipefail

FORCE_INSTALL=0
if (( $# > 1 )); then
    echo "Aufruf: $0 [--force-install]" >&2
    exit 2
elif (( $# == 1 )); then
    [[ "$1" == "--force-install" ]] || { echo "Unbekannte Option: $1" >&2; exit 2; }
    FORCE_INSTALL=1
fi

declare -a hard_findings=()
declare -a soft_findings=()

add_unique() {
    local array_name="$1" finding="$2" existing
    local -n destination="$array_name"
    for existing in "${destination[@]:-}"; do
        [[ "$existing" == "$finding" ]] && return 0
    done
    destination+=("$finding")
}

for binary in clamscan clamd clamdscan freshclam clamonacc sigtool; do
    if path="$(command -v "$binary" 2>/dev/null)"; then
        add_unique hard_findings "Programm gefunden: $binary ($path)"
    fi
done

if command -v pacman >/dev/null 2>&1 && pacman -Q clamav >/dev/null 2>&1; then
    package="$(pacman -Q clamav 2>/dev/null || true)"
    add_unique hard_findings "Installiertes Paket: ${package:-clamav}"
fi

if command -v dpkg-query >/dev/null 2>&1; then
    for package_name in clamav clamav-daemon clamav-freshclam; do
        if package="$(dpkg-query -W -f='${Package} ${Version} ${db:Status-Abbrev}' \
            "$package_name" 2>/dev/null)" && [[ "$package" == *" ii "* ]]; then
            add_unique hard_findings "Installiertes Paket: $package"
        fi
    done
fi

if command -v rpm >/dev/null 2>&1; then
    while IFS= read -r package; do
        [[ -n "$package" ]] && add_unique hard_findings "Installiertes Paket: $package"
    done < <(rpm -qa --qf '%{NAME}-%{VERSION}-%{RELEASE}\n' 2>/dev/null | \
        awk 'BEGIN { IGNORECASE=1 } /^clamav([.-]|$)/')
fi

if command -v systemctl >/dev/null 2>&1; then
    while read -r unit state _rest; do
        [[ -n "${unit:-}" ]] || continue
        case "$unit" in
            *[Cc][Ll][Aa][Mm][Aa][Vv]*|*[Cc][Ll][Aa][Mm][Dd]*|*[Ff][Rr][Ee][Ss][Hh][Cc][Ll][Aa][Mm]*) ;;
            *) continue ;;
        esac
        case "${state:-unknown}" in
            enabled|enabled-runtime)
                add_unique hard_findings "systemd-Unit ist für automatischen Start aktiviert: $unit ($state)"
                ;;
            *)
                add_unique soft_findings "inaktive/nicht aktivierte systemd-Unit registriert: $unit (${state:-Status unbekannt})"
                ;;
        esac
    done < <(systemctl list-unit-files --all --no-legend --no-pager 2>/dev/null || true)

    while read -r unit load active sub _rest; do
        [[ -n "${unit:-}" ]] || continue
        case "$unit" in
            *[Cc][Ll][Aa][Mm][Aa][Vv]*|*[Cc][Ll][Aa][Mm][Dd]*|*[Ff][Rr][Ee][Ss][Hh][Cc][Ll][Aa][Mm]*) ;;
            *) continue ;;
        esac
        if [[ "${active:-inactive}" != "inactive" ]]; then
            add_unique hard_findings "systemd-Unit ist/war gestartet: $unit (LOAD=${load:-?}, ACTIVE=${active:-?}, SUB=${sub:-?})"
        fi
    done < <(systemctl list-units --all --plain --no-legend --no-pager 2>/dev/null || true)
fi

for unit_dir in \
    /etc/systemd/system \
    /run/systemd/system \
    /usr/local/lib/systemd/system \
    /usr/lib/systemd/system \
    /lib/systemd/system; do
    [[ -d "$unit_dir" ]] || continue
    while IFS= read -r unit_file; do
        canonical_unit_file="$(readlink -f -- "$unit_file" 2>/dev/null || printf '%s' "$unit_file")"
        add_unique soft_findings "systemd-Unit-Datei/Template vorhanden: $canonical_unit_file"
    done < <(find "$unit_dir" -maxdepth 1 \( -type f -o -type l \) 2>/dev/null | \
        awk 'BEGIN { IGNORECASE=1 } /\/[^/]*(clamav|clamd|freshclam)[^/]*(@[^/]*)?\.(service|socket|timer|path|target)$/')
done

if (( ${#hard_findings[@]} > 0 )); then
    {
        echo "WARNUNG: ClamAV ist bereits installiert oder über systemd aktiviert/gestartet."
        echo "Der Installer nimmt keine Änderungen vor. --force-install kann diesen Konflikt nicht übergehen."
        echo
        printf '  - %s\n' "${hard_findings[@]}"
        if (( ${#soft_findings[@]} > 0 )); then
            echo
            echo "Zusätzlich gefundene Unit-Dateien/Templates:"
            printf '  - %s\n' "${soft_findings[@]}"
        fi
    } >&2
    exit 3
fi

if (( ${#soft_findings[@]} > 0 )); then
    if (( FORCE_INSTALL == 0 )); then
        {
            echo "WARNUNG: Es wurden ausschließlich inaktive beziehungsweise nicht aktivierte systemd-Unit-Dateien oder Templates gefunden."
            echo
            printf '  - %s\n' "${soft_findings[@]}"
            echo
            echo "Prüfe die Dateien und starte das System neu, damit keine alte Unit mehr geladen ist."
            echo "Danach kannst du die Installation bewusst freigeben mit:"
            echo "  ./install.sh --force-install"
            echo "oder über die TUI mit:"
            echo "  ./install-tui.sh --force-install"
        } >&2
        exit 4
    fi

    {
        echo "WARNUNG: --force-install übergeht ausschließlich folgende inaktive Unit-Dateien/Templates:"
        printf '  - %s\n' "${soft_findings[@]}"
        echo "Es wurden keine ClamAV-Binaries, Pakete oder aktiven/aktivierten Units gefunden."
    } >&2
fi

echo "Preflight-Prüfung erfolgreich: keine laufende oder installierte ClamAV-Installation gefunden."
