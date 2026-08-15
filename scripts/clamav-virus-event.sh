#!/usr/bin/env bash
set -u

VIRUS="${CLAM_VIRUSEVENT_VIRUSNAME:-unbekannt}"
FILE="${CLAM_VIRUSEVENT_FILENAME:-unbekannt}"

logger -p daemon.warning -t clamav-virus-event \
    "Malwarefund: virus=${VIRUS} file=${FILE}"

/usr/local/libexec/clamav-automation/clamav-mail.py \
    --kind virus \
    --virus "$VIRUS" \
    --file "$FILE" \
    --details "Fund wurde durch clamd/On-Access-Scanning gemeldet."
