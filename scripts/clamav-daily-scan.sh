#!/usr/bin/env bash
set -uo pipefail

CONFIG="/etc/clamav-automation/clamav-automation.conf"
LOGDIR="/var/log/clamav-automation"
MAILER="/usr/local/libexec/clamav-automation/clamav-mail.py"

# shellcheck source=/dev/null
source "$CONFIG"

mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/scan-$(date '+%Y%m%d-%H%M%S').log"

mapfile -t EXISTING_PATHS < <(
    for path in "${DAILY_SCAN_PATHS[@]}"; do
        [[ -e "$path" ]] && printf '%s\n' "$path"
    done
)

if (( ${#EXISTING_PATHS[@]} == 0 )); then
    echo "Keine konfigurierten Scanpfade vorhanden." | tee "$LOGFILE"
    logger -t clamav-daily-scan "Kein Scan ausgeführt: keine Scanpfade vorhanden"
    exit 0
fi

ARGS=(
    --config-file=/etc/clamav-automation/clamd.conf
    --fdpass
    --multiscan
    --infected
)

for regex in "${DAILY_EXCLUDE_REGEX[@]:-}"; do
    [[ -n "$regex" ]] && ARGS+=( "--exclude=$regex" )
done

{
    echo "=== ClamAV Daily Scan ==="
    echo "Start: $(date --iso-8601=seconds)"
    echo "Host: $(hostname -f 2>/dev/null || hostname)"
    echo "Pfade:"
    printf '  %s\n' "${EXISTING_PATHS[@]}"
    echo
} >"$LOGFILE"

set +e
clamdscan "${ARGS[@]}" "${EXISTING_PATHS[@]}" >>"$LOGFILE" 2>&1
RC=$?
set -e

{
    echo
    echo "Ende: $(date --iso-8601=seconds)"
    echo "Exit-Code: $RC"
} >>"$LOGFILE"

logger -t clamav-daily-scan "Scan beendet: rc=$RC log=$LOGFILE"

case "$RC" in
    0)
        ;;
    1)
        DETAILS="$(tail -n 150 "$LOGFILE")"
        FOUND="$(grep 'FOUND$' "$LOGFILE" || true)"
        "$MAILER" \
            --kind virus \
            --virus "siehe Scanbericht" \
            --file "$FOUND" \
            --details "$DETAILS" || \
            logger -p daemon.err -t clamav-daily-scan "Virus-Mail konnte nicht versendet werden"
        ;;
    *)
        DETAILS="$(tail -n 150 "$LOGFILE")"
        "$MAILER" \
            --kind scan-error \
            --details "$DETAILS" || \
            logger -p daemon.err -t clamav-daily-scan "Fehler-Mail konnte nicht versendet werden"
        ;;
esac

find "$LOGDIR" -type f -name 'scan-*.log' \
    -mtime "+${SCAN_LOG_RETENTION_DAYS:-30}" -delete 2>/dev/null || true

exit "$RC"
