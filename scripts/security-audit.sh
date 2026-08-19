#!/usr/bin/env bash
# Ergänzende, rein meldende Security-Audits für die unterstützten Distributionen.
set -Eeuo pipefail

CONFIG="${SECURITY_AUDIT_CONFIG:-/etc/clamav-automation/clamav-automation.conf}"
MAILER="${SECURITY_AUDIT_MAILER:-/usr/local/libexec/clamav-automation/clamav-mail.py}"
MODE="daily"
UPDATE_BASELINE=0
DRY_RUN=0
TMP_ROOT=""

usage() {
    cat <<EOF
Aufruf: $0 [--daily|--weekly|--incident] [--update-baseline] [--dry-run]

  --daily             leichter täglicher Audit (Standard)
  --weekly            tägliche plus Paketintegritäts- und YARA-Prüfungen
  --incident          vollständiger Audit plus Incident-Systeminformationen
  --update-baseline   Baselines explizit durch den aktuellen Zustand ersetzen
  --dry-run           keine Baselines, Reports oder Mails dauerhaft schreiben
EOF
}

while (( $# > 0 )); do
    case "$1" in
        --daily) MODE="daily" ;;
        --weekly) MODE="weekly" ;;
        --incident) MODE="incident" ;;
        --update-baseline) UPDATE_BASELINE=1 ;;
        --dry-run) DRY_RUN=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "Unbekannte Option: $1" >&2; usage >&2; exit 2 ;;
    esac
    shift
done

[[ -r "$CONFIG" ]] || { echo "Konfiguration nicht lesbar: $CONFIG" >&2; exit 2; }
# shellcheck source=/dev/null
source "$CONFIG"

bool_enabled() {
    case "${1,,}" in yes|true|1|on) return 0 ;; *) return 1 ;; esac
}

if ! bool_enabled "${SECURITY_AUDIT_ENABLED:-true}"; then
    echo "Security Audit ist deaktiviert."
    exit 0
fi

if [[ $EUID -ne 0 && $DRY_RUN -eq 0 ]] && ! bool_enabled "${SECURITY_AUDIT_TEST_MODE:-false}"; then
    echo "Security Audit muss als root ausgeführt werden." >&2
    exit 1
fi

if [[ -r /etc/os-release ]]; then
    # shellcheck source=/dev/null
    source /etc/os-release
fi
DISTRO_ID="${ID:-unknown}"
DISTRO_LIKE="${ID_LIKE:-}"
DISTRO_NAME="${PRETTY_NAME:-$DISTRO_ID}"

BASELINE_DIR="${SECURITY_BASELINE_DIR:-/var/lib/clamav-security/baselines}"
REPORT_DIR="${SECURITY_REPORT_DIR:-/var/log/clamav-security}"
YARA_RULE_DIR="${SECURITY_YARA_RULE_DIR:-/etc/clamav-security/yara}"
TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
ISO_TIME="$(date --iso-8601=seconds)"
HOST="$(hostname -f 2>/dev/null || hostname)"
PASSWD_FILE="${SECURITY_PASSWD_FILE:-/etc/passwd}"
GROUP_FILE="${SECURITY_GROUP_FILE:-/etc/group}"
SHADOW_FILE="${SECURITY_SHADOW_FILE:-/etc/shadow}"

TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clamav-security-audit.XXXXXX")"
# Wird indirekt durch trap aufgerufen.
# shellcheck disable=SC2329
cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT
chmod 0700 "$TMP_ROOT"

if (( DRY_RUN == 1 )); then
    EFFECTIVE_BASELINE_DIR="$TMP_ROOT/baselines"
    EFFECTIVE_REPORT_DIR="$TMP_ROOT/reports"
else
    EFFECTIVE_BASELINE_DIR="$BASELINE_DIR"
    EFFECTIVE_REPORT_DIR="$REPORT_DIR"
fi
install -d -m 0750 "$EFFECTIVE_BASELINE_DIR" "$EFFECTIVE_REPORT_DIR"
REPORT="$EFFECTIVE_REPORT_DIR/security-audit-${TIMESTAMP}-${MODE}.log"
touch "$REPORT"
chmod 0600 "$REPORT"

INFO_COUNT=0
WARNING_COUNT=0
CRITICAL_COUNT=0
declare -a FINDINGS=()

finding() {
    local severity="$1" id="$2" message="$3"
    case "$severity" in
        INFO) ((INFO_COUNT+=1)) ;;
        WARNING) ((WARNING_COUNT+=1)) ;;
        CRITICAL) ((CRITICAL_COUNT+=1)) ;;
        *) echo "Interner Fehler: ungültige Severity $severity" >&2; exit 2 ;;
    esac
    FINDINGS+=("[$severity][$id] $message")
}

snapshot_file() {
    local path="$1"
    [[ -f "$path" ]] || return 0
    printf '%s\t%s\n' "$path" "$(sha256sum "$path" | awk '{print $1}')"
}

snapshot_tree() {
    local path="$1" file
    [[ -e "$path" ]] || return 0
    if [[ -f "$path" ]]; then
        snapshot_file "$path"
        return
    fi
    while IFS= read -r -d '' file; do snapshot_file "$file"; done \
        < <(find "$path" -xdev -type f -print0 2>/dev/null)
}

store_current_and_compare() {
    local key="$1" current="$2" severity="$3" id="$4" label="$5"
    local baseline="$EFFECTIVE_BASELINE_DIR/$key.txt"
    local saved_current="$EFFECTIVE_REPORT_DIR/${TIMESTAMP}-${MODE}-${key}.current"
    local diff_file="$EFFECTIVE_REPORT_DIR/${TIMESTAMP}-${MODE}-${key}.diff"
    sort -u "$current" -o "$current"

    if (( UPDATE_BASELINE == 1 )); then
        install -m 0600 "$current" "$baseline"
        finding INFO "BASELINE-UPDATE" "Baseline '$key' wurde explizit aktualisiert."
        return
    fi

    if [[ ! -f "$baseline" ]]; then
        if (( DRY_RUN == 0 )); then install -m 0600 "$current" "$baseline"; fi
        finding INFO "BASELINE-NEW" "Keine Baseline für '$key'; initiale Baseline mit $(wc -l <"$current") Einträgen erstellt."
        return
    fi

    cp "$current" "$saved_current"
    chmod 0600 "$saved_current"
    if ! diff -u "$baseline" "$current" >"$diff_file"; then
        chmod 0600 "$diff_file"
        while IFS= read -r added; do
            [[ -n "$added" ]] && finding "$severity" "$id" "$label hinzugefügt/geändert: $added"
        done < <(comm -13 "$baseline" "$current")
        while IFS= read -r removed; do
            [[ -n "$removed" ]] && finding INFO "$id" "$label entfernt/geändert: $removed"
        done < <(comm -23 "$baseline" "$current")
    else
        rm -f "$diff_file"
    fi
}

check_users() {
    bool_enabled "${SECURITY_CHECK_USERS:-true}" || return 0
    local current="$TMP_ROOT/users"
    awk -F: '{print $1 ":" $3 ":" $4 ":" $6 ":" $7}' "$PASSWD_FILE" >"$current"
    store_current_and_compare users "$current" WARNING USER-001 "Benutzerkonto"

    while IFS=: read -r name uid _gid _home shell; do
        if [[ "$uid" == "0" && "$name" != "root" ]]; then
            finding CRITICAL USER-UID0 "Zusätzliches UID-0-Konto: $name ($shell)"
        fi
        case "$shell" in
            /bin/bash|/bin/sh|/bin/zsh|/bin/fish|/usr/bin/bash|/usr/bin/zsh|/usr/bin/fish|*/nologin|/bin/false|/usr/bin/false) ;;
            *) finding INFO USER-SHELL "Ungewöhnliche Login-Shell für $name: $shell" ;;
        esac
    done <"$current"

    current="$TMP_ROOT/account-files"
    : >"$current"
    for file in "$PASSWD_FILE" "$GROUP_FILE" "$SHADOW_FILE"; do snapshot_file "$file" >>"$current"; done
    store_current_and_compare account-files "$current" WARNING USER-FILES "Kontodatei"
}

check_systemd() {
    bool_enabled "${SECURITY_CHECK_SYSTEMD:-true}" || return 0
    local current="$TMP_ROOT/systemd-enabled" files="$TMP_ROOT/systemd-files"
    local files_baseline="$EFFECTIVE_BASELINE_DIR/systemd-files.txt" added_file unit_file
    {
        systemctl list-unit-files --type=service --state=enabled --no-legend --no-pager 2>/dev/null || true
        systemctl list-unit-files --type=timer --state=enabled --no-legend --no-pager 2>/dev/null || true
    } | awk '{print "enabled:" $1}' >"$current"
    systemctl list-timers --all --no-legend --no-pager 2>/dev/null | \
        awk 'NF >= 2 {print "timer-runtime:" $(NF-1) " -> " $NF}' >>"$current" || true
    store_current_and_compare systemd-enabled "$current" WARNING SYSTEMD-001 "Aktivierte systemd-Unit"

    : >"$files"
    for directory in /etc/systemd/system /usr/local/lib/systemd/system /usr/lib/systemd/system; do
        snapshot_tree "$directory" >>"$files"
    done
    sort -u "$files" -o "$files"
    if [[ -f "$files_baseline" && $UPDATE_BASELINE -eq 0 ]]; then
        while IFS= read -r added_file; do
            unit_file="${added_file%%$'\t'*}"
            [[ -f "$unit_file" ]] || continue
            if grep -Eiq '^[[:space:]]*ExecStart=.*(/tmp/|/var/tmp/|/dev/shm/|/home/|/root/)' "$unit_file"; then
                finding CRITICAL SYSTEMD-EXEC "Neue/geänderte Unit mit verdächtigem ExecStart: $unit_file"
            elif grep -Eiq '^[[:space:]]*ExecStart=.*/usr/local/' "$unit_file"; then
                finding WARNING SYSTEMD-EXEC "Neue/geänderte Unit startet Programm unter /usr/local: $unit_file"
            fi
        done < <(comm -13 "$files_baseline" "$files")
    fi
    store_current_and_compare systemd-files "$files" INFO SYSTEMD-002 "systemd-Unit-Datei"
}

check_cron() {
    bool_enabled "${SECURITY_CHECK_CRON:-true}" || return 0
    local current="$TMP_ROOT/cron"
    : >"$current"
    for path in /etc/crontab /etc/cron.d /etc/cron.hourly /etc/cron.daily \
        /etc/cron.weekly /etc/cron.monthly /var/spool/cron /var/spool/cron/crontabs; do
        snapshot_tree "$path" >>"$current"
    done
    store_current_and_compare cron "$current" WARNING CRON-001 "Cronjob"
}

check_ssh() {
    bool_enabled "${SECURITY_CHECK_SSH:-true}" || return 0
    local current="$TMP_ROOT/ssh" file key_hash file_hash key_line
    : >"$current"
    while IFS= read -r -d '' file; do
        file_hash="$(sha256sum "$file" | awk '{print $1}')"
        printf '%s\tFILE:%s\n' "$file" "$file_hash" >>"$current"
        while IFS= read -r key_line || [[ -n "$key_line" ]]; do
            [[ -n "$key_line" && "$key_line" != \#* ]] || continue
            key_hash="$(printf '%s' "$key_line" | sha256sum | awk '{print $1}')"
            printf '%s\tKEY:%s\n' "$file" "$key_hash" >>"$current"
        done <"$file"
    done < <(find /root /home -xdev -type f -name authorized_keys -print0 2>/dev/null)

    local baseline="$EFFECTIVE_BASELINE_DIR/ssh-authorized-keys.txt"
    sort -u "$current" -o "$current"
    if [[ -f "$baseline" && $UPDATE_BASELINE -eq 0 ]]; then
        while IFS= read -r added; do
            [[ -n "$added" ]] || continue
            if [[ "$added" == /root/* ]]; then
                finding CRITICAL SSH-001 "Neuer/geänderter root authorized_keys-Fingerprint: $added"
            else
                finding WARNING SSH-001 "Neuer/geänderter authorized_keys-Fingerprint: $added"
            fi
        done < <(comm -13 "$baseline" "$current")
    fi
    store_current_and_compare ssh-authorized-keys "$current" INFO SSH-001 "SSH-Key-Fingerprint"
}

check_suid() {
    bool_enabled "${SECURITY_CHECK_SUID:-true}" || return 0
    local current="$TMP_ROOT/suid"
    find / -xdev -type f \( -perm -4000 -o -perm -2000 \) -printf '%p\t%m\t%u:%g\n' 2>/dev/null >"$current"
    local baseline="$EFFECTIVE_BASELINE_DIR/suid-sgid.txt"
    sort -u "$current" -o "$current"
    if [[ -f "$baseline" && $UPDATE_BASELINE -eq 0 ]]; then
        while IFS= read -r added; do
            [[ -n "$added" ]] || continue
            case "$added" in
                /tmp/*|/var/tmp/*|/dev/shm/*|/home/*|/root/*|/usr/local/*)
                    finding CRITICAL SUID-001 "Neue SUID/SGID-Datei in kritischem Pfad: $added" ;;
                *) finding WARNING SUID-001 "Neue SUID/SGID-Datei: $added" ;;
            esac
        done < <(comm -13 "$baseline" "$current")
    fi
    store_current_and_compare suid-sgid "$current" INFO SUID-001 "SUID/SGID-Datei"
}

check_capabilities() {
    bool_enabled "${SECURITY_CHECK_CAPABILITIES:-true}" || return 0
    local current="$TMP_ROOT/capabilities"
    if ! command -v getcap >/dev/null 2>&1; then
        : >"$current"
        finding INFO CAP-TOOL "Optionales Werkzeug getcap fehlt."
    else
        getcap -r / 2>/dev/null >"$current" || true
    fi
    local baseline="$EFFECTIVE_BASELINE_DIR/capabilities.txt"
    sort -u "$current" -o "$current"
    if [[ -f "$baseline" && $UPDATE_BASELINE -eq 0 ]]; then
        while IFS= read -r added; do
            [[ -n "$added" ]] || continue
            if [[ "$added" =~ cap_(setuid|setgid|sys_admin|dac_override|sys_ptrace) ]]; then
                finding CRITICAL CAP-001 "Neue kritische File-Capability: $added"
            else
                finding WARNING CAP-001 "Neue File-Capability: $added"
            fi
        done < <(comm -13 "$baseline" "$current")
    fi
    store_current_and_compare capabilities "$current" INFO CAP-001 "File-Capability"
}

check_repositories() {
    bool_enabled "${SECURITY_CHECK_REPOSITORIES:-true}" || return 0
    local current="$TMP_ROOT/repositories"
    : >"$current"
    if [[ "$DISTRO_ID" =~ ^(arch|manjaro)$ || "$DISTRO_LIKE" == *arch* ]]; then
        snapshot_tree /etc/pacman.conf >>"$current"
        snapshot_tree /etc/pacman.d >>"$current"
        while IFS= read -r hit; do finding CRITICAL REPO-ARCH "Unsichere Pacman-Signaturkonfiguration: $hit"; done \
            < <(grep -RinsE '^[[:space:]]*SigLevel[[:space:]]*=.*(Never|TrustAll)' /etc/pacman.conf /etc/pacman.d 2>/dev/null || true)
    elif [[ "$DISTRO_ID" =~ ^(rhel|rocky)$ || "$DISTRO_LIKE" == *rhel* ]]; then
        snapshot_tree /etc/yum.repos.d >>"$current"
        snapshot_tree /etc/dnf >>"$current"
        while IFS= read -r hit; do finding WARNING REPO-RPM "Deaktivierte Repository-Sicherheitsprüfung: $hit"; done \
            < <(grep -RinsE '^[[:space:]]*(gpgcheck|repo_gpgcheck|sslverify)[[:space:]]*=[[:space:]]*0' /etc/yum.repos.d /etc/dnf 2>/dev/null || true)
    fi
    store_current_and_compare repositories "$current" WARNING REPO-001 "Repository-Konfiguration"
}

check_network() {
    bool_enabled "${SECURITY_CHECK_NETWORK:-false}" || return 0
    local current="$TMP_ROOT/network"
    if command -v ss >/dev/null 2>&1; then
        ss -lntupH 2>/dev/null | sed -E 's/users:\(.*\)$/users:(process)/' >"$current" || true
    else
        : >"$current"
        finding INFO NET-TOOL "Werkzeug ss fehlt."
    fi
    store_current_and_compare network-listeners "$current" WARNING NET-001 "Listening Socket"
}

check_foreign_packages() {
    local current="$TMP_ROOT/packages-foreign"
    command -v pacman >/dev/null 2>&1 || return 0
    pacman -Qm 2>/dev/null >"$current" || true
    store_current_and_compare packages-foreign "$current" WARNING PKG-AUR "Fremd-/AUR-Paket"
}

check_aur_sources() {
    bool_enabled "${SECURITY_CHECK_AUR_SOURCES:-false}" || return 0
    local source_dir source_file match line pattern
    local -a source_dirs=()
    if declare -p SECURITY_AUR_SOURCE_DIRS >/dev/null 2>&1; then
        source_dirs=("${SECURITY_AUR_SOURCE_DIRS[@]}")
    fi
    for source_dir in "${source_dirs[@]}"; do
        [[ -d "$source_dir" ]] || continue
        while IFS= read -r -d '' source_file; do
            while IFS= read -r match; do
                line="${match%%:*}"
                pattern="${match#*:}"
                finding WARNING AUR-001 \
                    "Heuristisches Muster in $source_file, Zeile $line: $pattern"
            done < <(grep -nEio 'curl|wget|ncat|socat|bash[[:space:]]+-c|sh[[:space:]]+-c|eval|base64|python[[:space:]]+-c|perl[[:space:]]+-e|ruby[[:space:]]+-e|npm[[:space:]]+install|bun|systemctl|crontab|authorized_keys|/dev/tcp' "$source_file" 2>/dev/null || true)
        done < <(find "$source_dir" -type f \( -name PKGBUILD -o -name '*.install' \) -print0 2>/dev/null)
    done
}

check_package_integrity() {
    bool_enabled "${SECURITY_CHECK_PACKAGES:-true}" || return 0
    local output="$TMP_ROOT/package-integrity"
    : >"$output"
    if [[ "$DISTRO_ID" =~ ^(arch|manjaro)$ || "$DISTRO_LIKE" == *arch* ]]; then
        check_foreign_packages
        check_aur_sources
        if command -v paccheck >/dev/null 2>&1; then
            paccheck --sha256sum --quiet >"$output" 2>&1 || true
        else
            finding INFO PKG-TOOL "paccheck fehlt; eingeschränkte Prüfung mit pacman -Qk."
            pacman -Qk 2>&1 | grep -vE ', 0 missing files$' >"$output" || true
        fi
        while IFS= read -r line; do [[ -n "$line" ]] && finding WARNING PKG-ARCH "Paketintegritätsabweichung: $line"; done <"$output"
    elif [[ "$DISTRO_ID" =~ ^(rhel|rocky)$ || "$DISTRO_LIKE" == *rhel* ]]; then
        rpm -Va >"$output" 2>&1 || true
        while IFS= read -r line; do
            [[ -n "$line" ]] || continue
            if [[ "$line" =~ (/usr/bin/sudo|/usr/sbin/sshd|/usr/bin/ssh|/usr/bin/su|/usr/bin/passwd|/usr/bin/login)$ ]]; then
                finding CRITICAL PKG-RPM "Kritische RPM-Integritätsabweichung: $line"
            elif [[ "$line" =~ /etc/ ]]; then
                finding INFO PKG-RPM "RPM-Konfigurationsabweichung: $line"
            else
                finding WARNING PKG-RPM "RPM-Integritätsabweichung: $line"
            fi
        done <"$output"
        rpm -qa 'gpg-pubkey*' 2>/dev/null >"$TMP_ROOT/gpg-keys" || true
        store_current_and_compare gpg-keys "$TMP_ROOT/gpg-keys" WARNING REPO-GPG "RPM-GPG-Key"
    fi
}

check_yara() {
    bool_enabled "${SECURITY_CHECK_YARA:-true}" || return 0
    if ! command -v yara >/dev/null 2>&1; then
        finding INFO YARA-TOOL "Optionales Werkzeug yara fehlt; YARA-Prüfung übersprungen."
        return
    fi
    if [[ ! -d "$YARA_RULE_DIR" ]]; then
        finding INFO YARA-RULES "Kein YARA-Regelverzeichnis: $YARA_RULE_DIR"
        return
    fi
    local rule path result
    local -a scan_paths=(/tmp /var/tmp /dev/shm /usr/local/bin /usr/local/sbin /root /home)
    if declare -p SECURITY_YARA_SCAN_PATHS >/dev/null 2>&1; then
        scan_paths=("${SECURITY_YARA_SCAN_PATHS[@]}")
    fi
    while IFS= read -r -d '' rule; do
        for path in "${scan_paths[@]}"; do
            [[ -e "$path" ]] || continue
            while IFS= read -r result; do
                [[ -n "$result" ]] && finding WARNING YARA-001 "YARA-Treffer ($rule): $result"
            done < <(yara -r "$rule" "$path" 2>/dev/null || true)
        done
    done < <(find "$YARA_RULE_DIR" -type f \( -name '*.yar' -o -name '*.yara' \) -print0 2>/dev/null)
}

check_clamav_health() {
    bool_enabled "${SECURITY_CHECK_CLAMAV:-true}" || return 0
    local newest_signature signature_epoch age_hours
    if systemctl is-active --quiet clamav-auto-clamd.service && \
       clamdscan --config-file=/etc/clamav-automation/clamd.conf --ping=1 >/dev/null 2>&1; then
        finding INFO CLAM-OK "clamd ist aktiv und antwortet."
    else
        finding CRITICAL CLAM-001 "clamd ist nicht aktiv oder antwortet nicht."
    fi
    if ! systemctl is-active --quiet clamav-auto-freshclam.timer; then
        finding WARNING CLAM-002 "FreshClam-Timer ist nicht aktiv."
    fi
    newest_signature="$(find /var/lib/clamav-automation/database -maxdepth 1 -type f \
        \( -name '*.cvd' -o -name '*.cld' \) -printf '%T@\n' 2>/dev/null | sort -n | tail -n1)"
    if [[ -z "$newest_signature" ]]; then
        finding CRITICAL CLAM-003 "Keine ClamAV-Signaturdatenbank gefunden."
    else
        signature_epoch="${newest_signature%%.*}"
        age_hours=$(( ($(date +%s) - signature_epoch) / 3600 ))
        if (( age_hours > 48 )); then
            finding WARNING CLAM-003 "Neueste ClamAV-Signaturdatei ist ${age_hours} Stunden alt."
        else
            finding INFO CLAM-DB "Neueste ClamAV-Signaturdatei ist ${age_hours} Stunden alt."
        fi
    fi
}

incident_appendix() {
    [[ "$MODE" == "incident" ]] || return 0
    {
        echo
        echo "INCIDENT APPENDIX"
        echo "================="
        for command_name in "ps auxf" "ss -pantul" "lsmod" "last" "lastlog"; do
            echo
            echo "--- $command_name ---"
            read -r -a command_parts <<<"$command_name"
            "${command_parts[@]}" 2>&1 || true
        done
        echo
        echo "--- journalctl (letzte 24 Stunden, warning+) ---"
        journalctl --since '24 hours ago' -p warning --no-pager 2>&1 || true
    } >>"$REPORT"
}

check_users
check_systemd
check_cron
check_ssh
check_suid
check_capabilities
check_repositories
check_network
check_clamav_health

if [[ "$MODE" == "weekly" || "$MODE" == "incident" || $UPDATE_BASELINE -eq 1 ]]; then
    check_package_integrity
    check_yara
fi

{
    echo "Host: $HOST"
    echo "Distribution: $DISTRO_NAME"
    echo "Timestamp: $ISO_TIME"
    echo "Mode: $MODE"
    echo
    echo "Security Audit Summary"
    echo "======================"
    echo "CRITICAL: $CRITICAL_COUNT"
    echo "WARNING: $WARNING_COUNT"
    echo "INFO: $INFO_COUNT"
    echo
    for severity in CRITICAL WARNING INFO; do
        echo "$severity FINDINGS"
        echo "-----------------"
        for entry in "${FINDINGS[@]:-}"; do
            [[ "$entry" == "[$severity]"* ]] && echo "$entry"
        done
        echo
    done
} >"$TMP_ROOT/report-head"
cat "$TMP_ROOT/report-head" "$REPORT" >"$TMP_ROOT/report-complete"
install -m 0600 "$TMP_ROOT/report-complete" "$REPORT"
incident_appendix

if (( DRY_RUN == 1 )); then
    cat "$REPORT"
    exit 0
fi

notify=0
(( CRITICAL_COUNT > 0 )) && bool_enabled "${SECURITY_NOTIFY_CRITICAL:-true}" && notify=1
(( WARNING_COUNT > 0 )) && bool_enabled "${SECURITY_NOTIFY_WARNING:-true}" && notify=1
(( INFO_COUNT > 0 )) && bool_enabled "${SECURITY_NOTIFY_INFO:-false}" && notify=1

if (( UPDATE_BASELINE == 1 )); then
    echo "Baseline-Aktualisierung abgeschlossen; es wird keine Mail versendet."
elif (( notify == 1 )) && bool_enabled "${SECURITY_AUDIT_MAIL_ON_FINDING:-true}"; then
    highest="INFO"
    (( WARNING_COUNT > 0 )) && highest="WARNING"
    (( CRITICAL_COUNT > 0 )) && highest="CRITICAL"
    "$MAILER" --kind security \
        --subject "[Security Audit][$highest] $HOST - $CRITICAL_COUNT critical / $WARNING_COUNT warnings" \
        --details-file "$REPORT" || \
        logger -p daemon.err -t clamav-security-audit "Audit-Mail konnte nicht versendet werden" || true
elif (( CRITICAL_COUNT == 0 && WARNING_COUNT == 0 )) && \
     bool_enabled "${SECURITY_AUDIT_HEARTBEAT:-true}"; then
    "$MAILER" --kind security --subject "[Security Audit][OK] $HOST" \
        --details-file "$REPORT" || \
        logger -p daemon.err -t clamav-security-audit "Audit-Heartbeat konnte nicht versendet werden" || true
fi

if ! bool_enabled "${SECURITY_AUDIT_TEST_MODE:-false}"; then
    logger -t clamav-security-audit \
        "mode=$MODE critical=$CRITICAL_COUNT warning=$WARNING_COUNT info=$INFO_COUNT report=$REPORT" || true
fi
echo "Security Audit abgeschlossen: CRITICAL=$CRITICAL_COUNT WARNING=$WARNING_COUNT INFO=$INFO_COUNT"
echo "Report: $REPORT"
exit 0
