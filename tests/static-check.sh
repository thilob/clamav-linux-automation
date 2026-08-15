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

echo "Prüfe erwartete Dateien..."
for f in \
    install.sh install-tui.sh uninstall.sh \
    config/clamav-automation.conf.example \
    config/dialogrc-as400 \
    scripts/config-functions.sh \
    scripts/preflight-check.sh \
    systemd/clamav-auto-clamd.service \
    systemd/clamav-auto-onaccess.service \
    systemd/clamav-auto-freshclam.service \
    systemd/clamav-auto-scan.service \
    systemd/clamav-auto-heartbeat.service; do
    [[ -f "$ROOT/$f" ]] || { echo "FEHLT: $f" >&2; exit 1; }
done

echo "Alle statischen Prüfungen erfolgreich."
