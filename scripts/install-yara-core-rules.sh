#!/usr/bin/env bash
# Lädt das aktuelle kuratierte Core-Regelpaket von YARA Forge und installiert es.
set -Eeuo pipefail

URL="${YARA_FORGE_CORE_URL:-https://github.com/YARAHQ/yara-forge/releases/latest/download/yara-forge-rules-core.zip}"
TARGET_DIR="${YARA_CORE_TARGET_DIR:-/etc/clamav-security/yara}"
TARGET="$TARGET_DIR/yara-forge-core.yar"
YARA_CORE_TMP_DIR="${YARA_CORE_TMP_DIR:-/var/lib/clamav-automation/tmp}"
[[ -d "$YARA_CORE_TMP_DIR" ]] || {
    echo "FEHLER: Sicheres temporäres Verzeichnis fehlt: $YARA_CORE_TMP_DIR" >&2
    exit 1
}
TMP_ROOT="$(mktemp -d "$YARA_CORE_TMP_DIR/yara-forge-core.XXXXXX")"
ARCHIVE="$TMP_ROOT/yara-forge-rules-core.zip"
RULES="$TMP_ROOT/yara-rules-core.yar"

cleanup() { rm -rf -- "$TMP_ROOT"; }
trap cleanup EXIT

[[ $EUID -eq 0 ]] || { echo "FEHLER: Bitte als root ausführen." >&2; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "FEHLER: python3 fehlt." >&2; exit 1; }
command -v yara >/dev/null 2>&1 || { echo "FEHLER: yara fehlt." >&2; exit 1; }

python3 - "$URL" "$ARCHIVE" <<'PY'
import pathlib
import sys
import urllib.request

url, destination = sys.argv[1:]
request = urllib.request.Request(url, headers={"User-Agent": "clamav-linux-automation"})
with urllib.request.urlopen(request, timeout=60) as response:
    if response.status != 200:
        raise RuntimeError(f"HTTP-Status {response.status}")
    pathlib.Path(destination).write_bytes(response.read())
PY

python3 - "$ARCHIVE" "$RULES" <<'PY'
import pathlib
import sys
import zipfile

archive, destination = sys.argv[1:]
member = "packages/core/yara-rules-core.yar"
with zipfile.ZipFile(archive) as bundle:
    bad = bundle.testzip()
    if bad is not None:
        raise RuntimeError(f"Beschädigter ZIP-Eintrag: {bad}")
    data = bundle.read(member)
if not data.startswith(b"/*") or b"rule " not in data:
    raise RuntimeError("Die erwartete YARA-Regeldatei ist inhaltlich unplausibel")
pathlib.Path(destination).write_bytes(data)
PY

# Kompiliert sämtliche Regeln; Ziel /dev/null erzeugt dabei keinen Treffer.
yara -w "$RULES" /dev/null >/dev/null

install -d -o root -g root -m 0750 "$TARGET_DIR"
install -o root -g root -m 0640 "$RULES" "$TARGET"
sha256sum "$TARGET" >"$TARGET.sha256"
chown root:root "$TARGET.sha256"
chmod 0640 "$TARGET.sha256"

echo "YARA-Forge-Core-Regeln installiert: $TARGET"
echo "SHA-256: $(sha256sum "$TARGET" | awk '{print $1}')"
