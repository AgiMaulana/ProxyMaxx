#!/bin/bash
#
# Packages the browser companions into Resources/browser, where the macOS app picks them up.
#
# Usage: Scripts/build-browser-extension.sh [--firefox-xpi PATH]
#
# Chromium stays unpacked. Firefox is a deterministic, unsigned XPI for temporary
# installation unless an externally signed XPI matching this checkout is supplied.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DESTINATION="$ROOT/Resources/browser"
SWIFT_BRIDGE="$ROOT/Sources/SystemKit/BrowserBridge.swift"
FIREFOX_XPI=""

while (( $# > 0 )); do
    case "$1" in
        --firefox-xpi)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                echo "Usage: $0 [--firefox-xpi PATH]" >&2
                exit 2
            fi
            FIREFOX_XPI="$2"
            shift 2
            ;;
        *) echo "Usage: $0 [--firefox-xpi PATH]" >&2; exit 2 ;;
    esac
done

if ! command -v python3 >/dev/null 2>&1; then
    echo "python3 is required to verify extension identities and package the Firefox XPI." >&2
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

    verify_panel_wiring "$SOURCE"

    echo "==> Staging the unpacked Chromium extension"
    rsync -a --delete --exclude 'AGENTS.md' --exclude '.DS_Store' "$SOURCE/" "$UNPACKED/"

    echo "    unpacked: $UNPACKED"
    echo "    id:       $EXPECTED_ID"
}

stage_firefox() {
    local SOURCE="$ROOT/Browser/FirefoxExtension"
    local XPI="$DESTINATION/proxymaxx-firefox-extension.xpi"

    if [[ ! -f "$SOURCE/manifest.json" ]]; then
        echo "No manifest at $SOURCE/manifest.json" >&2
        exit 1
    fi

    verify_panel_wiring "$SOURCE"
    python3 - "$SOURCE" "$SWIFT_BRIDGE" "$XPI" "$FIREFOX_XPI" <<'PY'
import hashlib
import io
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile
import zipfile

source, bridge, destination = map(Path, sys.argv[1:4])
signed_path = sys.argv[4]
manifest_bytes = (source / "manifest.json").read_bytes()
manifest = json.loads(manifest_bytes)
expected_id = manifest.get("browser_specific_settings", {}).get("gecko", {}).get("id")
declared = re.search(r'\bfirefoxExtensionID\s*=\s*"([^"]+)"', bridge.read_text())
if not expected_id or not declared or expected_id != declared.group(1):
    sys.exit("The Firefox manifest ID and BrowserBridge.firefoxExtensionID disagree.")
version = manifest.get("version")
if not isinstance(version, str) or not version:
    sys.exit("The Firefox manifest has no version.")
print("==> Verifying the Firefox extension identity")
print(f"    id:       {expected_id}")
print(f"    version:  {version}")

popup = manifest["action"]["default_popup"]
runtime_names = {"manifest.json", popup, *manifest["background"]["scripts"]}
runtime_names.update(re.findall(r'(?:src|href)="([^"]+)"', (source / popup).read_text()))
if any(Path(name).name != name for name in runtime_names):
    sys.exit("Firefox runtime assets must be files at the XPI root.")
runtime = {name: (source / name).read_bytes() for name in sorted(runtime_names)}
runtime["manifest.json"] = manifest_bytes

if signed_path:
    payload = Path(signed_path).read_bytes()
    jar_signature = {"META-INF/manifest.mf", "META-INF/mozilla.sf", "META-INF/mozilla.rsa"}
    cose_signature = {"META-INF/cose.manifest", "META-INF/cose.sig"}
    metadata_names = jar_signature | cose_signature
    try:
        with zipfile.ZipFile(io.BytesIO(payload)) as archive:
            entries = archive.infolist()
            names = [entry.filename for entry in entries]
            if len(names) != len(set(names)):
                sys.exit("The supplied Firefox XPI has duplicate ZIP entries.")
            if any(entry.is_dir() and entry.filename != "META-INF/" for entry in entries):
                sys.exit("The supplied Firefox XPI contains an unexpected directory.")
            if any((entry.external_attr >> 16) & 0o170000 == 0o120000 for entry in entries):
                sys.exit("The supplied Firefox XPI contains a symbolic link.")
            files = {entry.filename for entry in entries if not entry.is_dir()}
            if files - metadata_names != runtime.keys():
                sys.exit("The supplied Firefox XPI has missing or unexpected runtime files.")
            packaged_manifest = json.loads(archive.read("manifest.json"))
            packaged_id = packaged_manifest.get("browser_specific_settings", {}).get("gecko", {}).get("id")
            if packaged_id != expected_id or packaged_manifest.get("version") != version:
                sys.exit("The supplied Firefox XPI has the wrong add-on ID or version.")
            for name, expected_bytes in runtime.items():
                if archive.read(name) != expected_bytes:
                    sys.exit(f"The supplied Firefox XPI is stale or changed: {name} differs from source.")
            present_metadata = files & metadata_names
            if not (jar_signature <= present_metadata or cose_signature <= present_metadata):
                sys.exit("The supplied Firefox XPI is unsigned: Mozilla signature metadata is missing.")
            for group in (jar_signature, cose_signature):
                if present_metadata & group and not group <= present_metadata:
                    sys.exit("The supplied Firefox XPI has incomplete Mozilla signature metadata.")
            if any(not archive.read(name) for name in present_metadata):
                sys.exit("The supplied Firefox XPI has empty Mozilla signature metadata.")
    except (zipfile.BadZipFile, RuntimeError, ValueError, KeyError) as error:
        sys.exit(f"Invalid supplied Firefox XPI: {error}")
    print("==> Copying supplied Firefox XPI bytes unchanged")
    print("    signature metadata present; cryptographic signature not verified")
else:
    buffer = io.BytesIO()
    with zipfile.ZipFile(buffer, "w", compression=zipfile.ZIP_DEFLATED, compresslevel=9) as archive:
        for name, data in runtime.items():
            entry = zipfile.ZipInfo(name, date_time=(1980, 1, 1, 0, 0, 0))
            entry.create_system = 3
            entry.external_attr = 0o100644 << 16
            entry.compress_type = zipfile.ZIP_DEFLATED
            archive.writestr(entry, data, compresslevel=9)
    payload = buffer.getvalue()
    print("==> Packaging unsigned Firefox XPI (temporary-install-only)")
    print("    Firefox: about:debugging > This Firefox > Load Temporary Add-on")
    print("    Persistent installation requires a Mozilla-signed XPI supplied with --firefox-xpi PATH.")

destination.parent.mkdir(parents=True, exist_ok=True)
with tempfile.NamedTemporaryFile(dir=destination.parent, suffix=".xpi", delete=False) as staged:
    temporary = Path(staged.name)
    try:
        staged.write(payload)
        staged.flush()
        os.chmod(temporary, 0o644)
        os.replace(temporary, destination)
    finally:
        temporary.unlink(missing_ok=True)
obsolete = destination.with_suffix("")
if obsolete.is_dir():
    shutil.rmtree(obsolete)
elif obsolete.exists():
    obsolete.unlink()
print(f"    xpi:      {destination}")
print(f"    digest:   sha256:{hashlib.sha256(payload).hexdigest()}")
PY
}

function verify_panel_wiring() {
    local root="$1"
    python3 - "$root" <<'PY'
import json, os, re, sys

root = sys.argv[1]
manifest = json.load(open(os.path.join(root, "manifest.json")))
html = open(os.path.join(root, "popup.html")).read()
if manifest.get("action", {}).get("default_popup") != "popup.html":
    sys.exit("The manifest action must load popup.html.")

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
# Keep Chromium's unpacked-tree digest; Firefox reports the XPI byte digest above.
staged="$DESTINATION/proxymaxx-extension"
( cd "$staged" && find . -type f | LC_ALL=C sort | xargs shasum -a 256 | shasum -a 256 ) \
    | awk -v d="$staged" '{print "    tree:     " d ": sha256:" $1}'
