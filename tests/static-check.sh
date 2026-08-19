#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Bash Syntaxprüfung..."
while IFS= read -r -d '' f; do
    bash -n "$f"
    echo "  OK $f"
done < <(find "$ROOT" -type f -name '*.sh' -print0)

echo "Python Syntaxprüfung..."
PYCACHE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/clamav-pycache.XXXXXX")"
PYTHONPYCACHEPREFIX="$PYCACHE_DIR" python3 -m py_compile "$ROOT/scripts/clamav-mail.py"
rm -rf -- "$PYCACHE_DIR"

echo "Prüfe Distributionserkennung ohne VERSION_ID..."
# Der einfach quotierte Code soll absichtlich erst in der inneren Bash expandieren.
# shellcheck disable=SC2016
env -i PATH="$PATH" bash -u -c '
    source "$1"
    distro_id_raw="${ID:-}"
    distro_id="${distro_id_raw,,}"
    distro_like="${ID_LIKE:-}"
    version_id_value="${VERSION_ID:-}"
    version_major="${version_id_value%%.*}"
    [[ -n "$distro_id" ]]
    : "$distro_like" "$version_major"
' _ /etc/os-release

echo "Prüfe Debian-Paketierung..."
grep -q 'apt-get install' "$ROOT/install.sh"
for package in clamav clamav-daemon clamav-freshclam clamdscan; do
    grep -q "${package}" "$ROOT/install.sh"
done

echo "Prüfe erwartete Dateien..."
for f in \
    install.sh install-tui.sh uninstall.sh \
    config/clamav-automation.conf.example \
    config/dialogrc-as400 \
    scripts/config-functions.sh \
    scripts/install-yara-core-rules.sh \
    scripts/upgrade-installation.sh \
    scripts/clamav-wait-for-clamd.sh \
    scripts/security-audit.sh \
    scripts/preflight-check.sh \
    tests/security-audit-baseline-test.sh \
    systemd/clamav-auto-clamd.service \
    systemd/clamav-auto-onaccess.service \
    systemd/clamav-auto-freshclam.service \
    systemd/clamav-auto-scan.service \
    systemd/clamav-auto-heartbeat.service \
    systemd/clamav-auto-security-daily.service \
    systemd/clamav-auto-security-weekly.service; do
    [[ -f "$ROOT/$f" ]] || { echo "FEHLT: $f" >&2; exit 1; }
done

echo "Prüfe YARA-Forge-Core-Integration..."
grep -q 'yara-forge-rules-core.zip' "$ROOT/scripts/install-yara-core-rules.sh"
grep -q -- '--install-yara-core' "$ROOT/install.sh"
grep -q -- '--install-yara-core' "$ROOT/install-tui.sh"

echo "Prüfe Security-Audit-Dry-Run..."
SECURITY_AUDIT_CONFIG="$ROOT/tests/security-audit-test.conf" \
    "$ROOT/scripts/security-audit.sh" --weekly --dry-run | \
    grep -q '^CRITICAL: 0$'

"$ROOT/tests/security-audit-baseline-test.sh"

echo "Alle statischen Prüfungen erfolgreich."
