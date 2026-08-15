#!/usr/bin/env bash
set -Eeuo pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"
TEST_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/clamav-security-test.XXXXXX")"
cleanup() { rm -rf -- "$TEST_ROOT"; }
trap cleanup EXIT

mkdir -p "$TEST_ROOT/baselines" "$TEST_ROOT/reports"
printf '%s\n' \
    'root:x:0:0:root:/root:/bin/bash' \
    'audituser:x:1000:1000:Audit:/home/audituser:/bin/bash' >"$TEST_ROOT/passwd"
printf '%s\n' 'root:x:0:' 'audituser:x:1000:' >"$TEST_ROOT/group"
printf '%s\n' 'root:!:20000::::::' 'audituser:!:20000::::::' >"$TEST_ROOT/shadow"

cat >"$TEST_ROOT/config" <<EOF
SECURITY_AUDIT_ENABLED="true"
SECURITY_AUDIT_TEST_MODE="true"
SECURITY_BASELINE_DIR="$TEST_ROOT/baselines"
SECURITY_REPORT_DIR="$TEST_ROOT/reports"
SECURITY_PASSWD_FILE="$TEST_ROOT/passwd"
SECURITY_GROUP_FILE="$TEST_ROOT/group"
SECURITY_SHADOW_FILE="$TEST_ROOT/shadow"
SECURITY_CHECK_USERS="true"
SECURITY_CHECK_SYSTEMD="false"
SECURITY_CHECK_CRON="false"
SECURITY_CHECK_SSH="false"
SECURITY_CHECK_SUID="false"
SECURITY_CHECK_CAPABILITIES="false"
SECURITY_CHECK_PACKAGES="false"
SECURITY_CHECK_REPOSITORIES="false"
SECURITY_CHECK_NETWORK="false"
SECURITY_CHECK_YARA="false"
SECURITY_CHECK_CLAMAV="false"
SECURITY_AUDIT_MAIL_ON_FINDING="false"
SECURITY_AUDIT_HEARTBEAT="false"
EOF

SECURITY_AUDIT_CONFIG="$TEST_ROOT/config" "$ROOT/scripts/security-audit.sh" --daily >/dev/null
[[ -s "$TEST_ROOT/baselines/users.txt" ]]

SECURITY_AUDIT_CONFIG="$TEST_ROOT/config" "$ROOT/scripts/security-audit.sh" --daily >/dev/null
second_report="$(find "$TEST_ROOT/reports" -type f -name 'security-audit-*-daily.log' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)"
grep -q '^CRITICAL: 0$' "$second_report"
grep -q '^WARNING: 0$' "$second_report"

printf '%s\n' 'backdoor:x:0:0:Backdoor:/root:/bin/bash' >>"$TEST_ROOT/passwd"
SECURITY_AUDIT_CONFIG="$TEST_ROOT/config" "$ROOT/scripts/security-audit.sh" --daily >/dev/null
third_report="$(find "$TEST_ROOT/reports" -type f -name 'security-audit-*-daily.log' -printf '%T@ %p\n' | sort -n | tail -n1 | cut -d' ' -f2-)"
grep -q 'Zusätzliches UID-0-Konto: backdoor' "$third_report"

echo "Security-Audit-Baseline-Tests erfolgreich."
