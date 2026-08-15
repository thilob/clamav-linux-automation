#!/usr/bin/env bash
# Wartet, bis clamd seine Signaturen geladen hat und über den Projektsocket antwortet.
set -Eeuo pipefail

CONFIG="/etc/clamav-automation/clamd.conf"
TIMEOUT="${1:-180}"

[[ "$TIMEOUT" =~ ^[1-9][0-9]*$ ]] || {
    echo "FEHLER: Timeout muss eine positive ganze Zahl sein: $TIMEOUT" >&2
    exit 2
}

deadline=$(( SECONDS + TIMEOUT ))
next_status=0
while (( SECONDS < deadline )); do
    if clamdscan --config-file="$CONFIG" --ping=1 >/dev/null 2>&1; then
        echo "clamd antwortet über den Projektsocket."
        exit 0
    fi
    if (( SECONDS >= next_status )); then
        echo "Warte auf clamd (noch maximal $(( deadline - SECONDS ))s) ..."
        next_status=$(( SECONDS + 10 ))
    fi
    sleep 2
done

echo "FEHLER: clamd antwortet nach ${TIMEOUT}s nicht über den Projektsocket." >&2
exit 1
