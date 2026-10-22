#!/bin/bash
#
# Builds every companion and the app bundle in one pass.
#
# Usage: Scripts/build-all.sh [debug|release]
#
# This is the entry point CI calls, and the one a release should use. It differs from
# Scripts/bundle-app.sh only in always building the Android tunnel, whose Gradle build
# needs a JDK and the Android SDK that day-to-day development should not require.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="${1:-debug}"

case "$CONFIGURATION" in
    debug|release) ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

exec "$ROOT/Scripts/bundle-app.sh" "$CONFIGURATION" --with-android-vpn
