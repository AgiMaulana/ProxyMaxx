#!/bin/bash
#
# Builds the proxymaxx-cli binary and puts it where the other build artifacts go.
#
# Usage: Scripts/build-cli.sh [debug|release]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"

case "$CONFIGURATION" in
    debug)   BIN_DIR="debug" ;;   # swift build uses the same layout as the app bundle
    release) BIN_DIR="release" ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

cd "$ROOT"

echo "==> Building proxymaxx-cli ($CONFIGURATION)"
swift build --product proxymaxx-cli -c "$CONFIGURATION"

# Ask SwiftPM for the path rather than reconstructing it: the build root can be
# redirected (as this checkout does), so --show-bin-path is the only source of truth.
BIN_PATH="$(swift build --product proxymaxx-cli -c "$CONFIGURATION" --show-bin-path)"
BINARY="$BIN_PATH/proxymaxx-cli"

if [[ ! -x "$BINARY" ]]; then
    echo "❌ The build finished without producing $BINARY" >&2
    exit 1
fi

echo "==> Sanity check"
"$BINARY" --help >/dev/null

# The CLI travels inside the app bundle, so it is staged where the other bundled
# artifacts live and Scripts/bundle-app.sh copies it from there.
DESTINATION="$ROOT/Resources/proxymaxx-cli"
mkdir -p "$ROOT/Resources"
# Copy under a temp name and rename, rather than overwriting the previous binary
# in place: macOS kills anything that execs (or even reads) a running binary's
# clobbered inode while it revalidates it. A fresh inode avoids that entirely.
STAGED="$DESTINATION.new"
cp "$BINARY" "$STAGED"
chmod +x "$STAGED"
# Re-sign explicitly: SwiftPM produces an ad-hoc signature, but restamping after
# the copy costs nothing and keeps the seal matching the shipped bytes.
codesign --force --sign - "$STAGED" >/dev/null 2>&1 || true
mv -f "$STAGED" "$DESTINATION"

echo "==> Wrote $DESTINATION"
shasum -a 256 "$DESTINATION" | awk '{print "    sha256: " $1}'
echo "    Try it: $DESTINATION rule list"
echo "    Bundles to: ProxyMaxx.app/Contents/Resources/proxymaxx-cli"
