#!/bin/bash
#
# Packages the browser companions into Resources/browser, where the macOS app picks them up.
#
# Usage: Scripts/build-browser-extension.sh
#
# Each extension is plain files, so there is no compiler step: this verifies every fixed
# extension identity the other parts depend on, then stages the unpacked folders the
# browsers load. One artifact each, like the Android APK — the app bundles them and
# reveals them.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$ROOT/Resources/browser"
SWIFT_BRIDGE="$ROOT/Sources/SystemKit/BrowserBridge.swift"

if ! command -v python3 >/dev/null 2>&1; then
    echo "❌ python3 is required to derive the extension identity from the manifest key." >&2
    exit 1
fi

if [[ ! -f "$SWIFT_BRIDGE" ]]; then
    echo "❌ Missing $SWIFT_BRIDGE." >&2
    exit 1
fi

stage_chromium() {
    local SOURCE="$ROOT/Browser/ProxyMaxxExtension"
    local UNPACKED="$DESTINATION/proxymaxx-extension"
    local EXPECTED_ID DECLARED_ID

    if [[ ! -f "$SOURCE/manifest.json" ]]; then
        echo "❌ No manifest at $SOURCE/manifest.json" >&2
        exit 1
    fi

    # Chrome derives the extension ID from the DER public key in the manifest. The native
    # messaging host whitelists that exact origin, so a mismatch is a silent, confusing
    # failure at runtime — check it here instead.
    echo "==> Verifying the Chromium extension identity"
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

    echo "==> Staging the unpacked Chromium extension"
    rsync -a --delete --exclude 'AGENTS.md' --exclude '.DS_Store' "$SOURCE/" "$UNPACKED/"

    verify_panel_wiring "$UNPACKED"

    echo "    unpacked: $UNPACKED"
    echo "    id:       $EXPECTED_ID"
}

stage_firefox() {
    local SOURCE="$ROOT/Browser/FirefoxExtension"
    local UNPACKED="$DESTINATION/proxymaxx-firefox-extension"
    local EXPECTED_ID DECLARED_ID

    if [[ ! -f "$SOURCE/manifest.json" ]]; then
        echo "❌ No manifest at $SOURCE/manifest.json" >&2
        exit 1
    fi

    # Unlike Chrome, Firefox pins the identity itself: the add-on ID is the one declared in
    # browser_specific_settings.gecko.id, and the native messaging host manifest
    # whitelists that ID. Check the two agree so a silent rename cannot break the channel.
    echo "==> Verifying the Firefox extension identity"
    EXPECTED_ID="$(python3 - "$SOURCE/manifest.json" <<'PY'
import json, sys
manifest = json.load(open(sys.argv[1]))
print(manifest.get("browser_specific_settings", {}).get("gecko", {}).get("id", ""))
PY
)"

    DECLARED_ID="$(grep -o 'firefoxExtensionID = "[^"]*"' "$SWIFT_BRIDGE" | head -1 | sed 's/.*"\(.*\)"/\1/')"

    echo "    derived:  $EXPECTED_ID"
    echo "    declared: $DECLARED_ID"

    if [[ -z "$DECLARED_ID" || "$EXPECTED_ID" != "$DECLARED_ID" ]]; then
        echo "❌ The manifest ID ($EXPECTED_ID) and BrowserBridge.firefoxExtensionID ($DECLARED_ID) disagree." >&2
        echo "   Update Sources/SystemKit/BrowserBridge.swift to \"$EXPECTED_ID\", and re-run." >&2
        exit 1
    fi

    echo "==> Staging the unpacked Firefox extension"
    rsync -a --delete --exclude 'AGENTS.md' --exclude '.DS_Store' "$SOURCE/" "$UNPACKED/"

    verify_panel_wiring "$UNPACKED"

    echo "    unpacked: $UNPACKED"
    echo "    id:       $EXPECTED_ID"
}

function verify_panel_wiring() {
    local root="$1"
    python3 - "$root" <<'PY'
import json, os, re, sys

root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json")))
html = open(os.path.join(root, "popup.html")).read()

loaded = set(re.findall(r'(?:src|href)="([^"]+)"', html))

# Chromium's service worker; Firefox declares scripts instead.
background = manifest.get("background", {})
if "service_worker" in background:
    loaded.add(background["service_worker"])
if "scripts" in background:
    loaded.update(background["scripts"])

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

print(f"    panel loads: {', '.join(sorted(n for n in loaded if n.endswith(('.js', '.css'))))}")
PY
}

stage_chromium
stage_firefox

echo "==> Done"
# Digests of the staged trees, so two machines can prove they built the same artifacts.
for staged in "$DESTINATION"/*/; do
    ( cd "$staged" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 ) \
        | awk -v d="${staged%/}" '{print "    tree:     " d ": sha256:" $1}'
done
