#!/bin/bash
#
# Builds the Android tunnel app and puts the APK where the macOS app expects it.
#
# Usage: Scripts/build-android-vpn.sh [debug|release]
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROJECT="$ROOT/Android/ProxyMaxxVpn"
DESTINATION="$ROOT/Resources/android"
CONFIGURATION="${1:-debug}"

case "$CONFIGURATION" in
    debug)   TASK="assembleDebug";   VARIANT="debug" ;;
    release) TASK="assembleRelease"; VARIANT="release" ;;
    *) echo "Usage: $0 [debug|release]" >&2; exit 2 ;;
esac

if [[ -z "${JAVA_HOME:-}" ]] && ! command -v java >/dev/null 2>&1; then
    echo "❌ No JDK found. Install one (Android Studio bundles one) and set JAVA_HOME." >&2
    exit 1
fi

SDK="${ANDROID_SDK_ROOT:-${ANDROID_HOME:-$HOME/Library/Android/sdk}}"
if [[ ! -d "$SDK/platforms" ]]; then
    echo "❌ No Android SDK at $SDK." >&2
    echo "   Install Android Studio, or set ANDROID_SDK_ROOT to an SDK with platform 36." >&2
    exit 1
fi

echo "==> Building the tunnel app ($CONFIGURATION)"
cd "$PROJECT"
./gradlew ":app:$TASK" --no-daemon --no-configuration-cache

APK_DIR="$PROJECT/app/build/outputs/apk/$VARIANT"
APK="$APK_DIR/app-$VARIANT.apk"
# A release build without signing credentials emits app-release-unsigned.apk. Stage it
# rather than failing, but say so: an unsigned APK runs on an emulator and nowhere else.
if [[ ! -f "$APK" && -f "$APK_DIR/app-$VARIANT-unsigned.apk" ]]; then
    APK="$APK_DIR/app-$VARIANT-unsigned.apk"
    echo "⚠️  No signing credentials (STORE_FILE, STORE_PASSWORD, KEY_ALIAS, KEY_PASSWORD)," >&2
    echo "   so the APK is unsigned. Set them to produce an installable release APK." >&2
fi

if [[ ! -f "$APK" ]]; then
    echo "❌ The build finished without producing an APK in $APK_DIR" >&2
    exit 1
fi

mkdir -p "$DESTINATION"
cp "$APK" "$DESTINATION/proxymaxx-vpn.apk"

echo "==> Wrote $DESTINATION/proxymaxx-vpn.apk"
shasum -a 256 "$DESTINATION/proxymaxx-vpn.apk" | awk '{print "    sha256: " $1}'
