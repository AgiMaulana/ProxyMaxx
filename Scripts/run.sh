#!/bin/bash
#
# Runs the app from SwiftPM with the localization files beside the binary.
#
# Usage: Scripts/run.sh [debug|release] [app arguments...]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="debug"
if [[ "${1:-}" == "debug" || "${1:-}" == "release" ]]; then
    CONFIGURATION="$1"
    shift
fi

cd "$ROOT"

# Without these the binary records the deployment target as its SDK and macOS renders the
# pre-Tahoe interface while the released app renders the current one — see the file.
source "$ROOT/Scripts/macos-sdk-flags.sh"

swift build -c "$CONFIGURATION" "${MACOS_SDK_LINK_FLAGS[@]}"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

# SwiftUI resolves LocalizedStringKey through Bundle.main. For an unbundled
# executable that is the directory holding the binary, so put the .lproj folders
# there before launching. The packaged app gets them from Contents/Resources.
for lproj in "$ROOT"/Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    rm -rf "$BIN_PATH/$(basename "$lproj")"
    cp -R "$lproj" "$BIN_PATH/"
done

exec "$BIN_PATH/ProxyMaxxApp" "$@"
