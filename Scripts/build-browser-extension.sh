#!/bin/bash
#
# Packages the browser companion into Resources/browser, where the macOS app picks it up.
#
# Usage: Scripts/build-browser-extension.sh
#
# The extension is plain files, so there is no compiler step: this verifies the fixed
# extension identity every other part depends on, then stages the unpacked folder the
# browser loads. One artifact, like the Android APK — the app bundles it and reveals it.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$ROOT/Browser/ProxyMaxxExtension"
DESTINATION="$ROOT/Resources/browser"
UNPACKED="$DESTINATION/proxymaxx-extension"
SWIFT_BRIDGE="$ROOT/Sources/SystemKit/BrowserBridge.swift"

if [[ ! -f "$SOURCE/manifest.json" ]]; then
    echo "❌ No manifest at $SOURCE/manifest.json" >&2
    exit 1
fi

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 is required to derive the extension ID from the manifest key." >&2
    exit 1
fi

# Chrome derives the extension ID from the DER public key in the manifest. The native
# messaging host whitelists that exact origin, so a mismatch is a silent, confusing
# failure at runtime — check it here instead.
echo "==> Verifying the extension identity"
EXPECTED_ID="$(python3 - "$SOURCE/manifest.json" <<'PY'
import base64, hashlib, json, sys
manifest = json.load(open(sys.argv[1]))
key = manifest.get("key")
if not key:
    sys.exit("the manifest has no \"key\", so the extension ID would not be stable")
der = base64.b64decode(key)
digest = hashlib.sha256(der).hexdigest()[:32]
print("".join(chr(ord("a") + int(nibble, 16)) for nibble in digest))
PY
)"

DECLARED_ID="$(grep -o 'extensionID = "[a-p]*"' "$SWIFT_BRIDGE" | head -1 | sed 's/.*"\(.*\)"/\1/')"

echo "    derived:  $EXPECTED_ID"
echo "    declared: $DECLARED_ID"

if [[ -z "$DECLARED_ID" || "$EXPECTED_ID" != "$DECLARED_ID" ]]; then
    echo "❌ The manifest key and BrowserBridge.extensionID disagree." >&2
    echo "   Update Sources/SystemKit/BrowserBridge.swift to $EXPECTED_ID, and re-run." >&2
    exit 1
fi

echo "==> Staging the unpacked extension"
rm -rf "$UNPACKED"
mkdir -p "$UNPACKED"
rsync -a --exclude 'AGENTS.md' --exclude '.DS_Store' "$SOURCE/" "$UNPACKED/"

# A panel that renders its HTML but never loads its script fails in complete silence: the
# popup shows its placeholder, chrome://extensions reports no error, and the worker is never
# messaged. Nothing else in the build would notice. So check the wiring explicitly.
echo "==> Verifying the panel wiring"
python3 - "$UNPACKED" <<'PY'
import json, os, re, sys

root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json")))
html = open(os.path.join(root, "popup.html")).read()

loaded = set(re.findall(r'(?:src|href)="([^"]+)"', html))
loaded.add(manifest["background"]["service_worker"])

problems = [
    f"referenced but absent: {name}"
    for name in sorted(loaded)
    if not os.path.exists(os.path.join(root, name))
]
present_scripts = sorted(name for name in os.listdir(root) if name.endswith(".js"))
problems += [
    f"present but never loaded by anything: {name}"
    for name in present_scripts
    if name not in loaded
]

if problems:
    print("❌ " + "\n❌ ".join(problems))
    sys.exit(1)

print(f"    popup.html loads: {', '.join(sorted(n for n in loaded if n.endswith(('.js', '.css'))))}")
PY

echo "==> Done"
echo "    unpacked: $UNPACKED"
echo "    id:       $EXPECTED_ID"

# A digest of the staged tree, so two machines can prove they built the same artifact.
( cd "$UNPACKED" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 ) \
    | awk '{print "    tree:     sha256:" $1}'
