#!/usr/bin/env bash
set -Eeuo pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd)"

echo "Bash Syntaxprüfung..."
while IFS= read -r -d '' f; do
    bash -n "$f"
    echo "  OK $f"
done < <(find "$ROOT" -type f -name '*.sh' -print0)

echo "Python Syntaxprüfung..."
python3 -m py_compile "$ROOT/scripts/clamav-mail.py"

echo "Prüfe erwartete Dateien..."
for f in \
    install.sh uninstall.sh \
    config/clamav-automation.conf.example \
    systemd/clamav-auto-clamd.service \
    systemd/clamav-auto-onaccess.service \
    systemd/clamav-auto-freshclam.service \
    systemd/clamav-auto-scan.service \
    systemd/clamav-auto-heartbeat.service; do
    [[ -f "$ROOT/$f" ]] || { echo "FEHLT: $f" >&2; exit 1; }
done

echo "Alle statischen Prüfungen erfolgreich."
