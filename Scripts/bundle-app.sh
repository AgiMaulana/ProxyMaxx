#!/bin/bash
#
# Builds ProxyMaxx, builds the companions it ships, and wraps the result in a runnable
# .app bundle.
#
# Usage: Scripts/bundle-app.sh [debug|release] [--with-android-vpn] [--firefox-xpi PATH]
#
# The CLI and the browser extension always come from this checkout. The Android tunnel
# needs a JDK and the Android SDK, so it is built only when asked for — but a release
# bundle refuses to ship without it.
#
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
CONFIGURATION="debug"
BUILD_ANDROID_VPN=0
FIREFOX_XPI=""

while (( $# > 0 )); do
    case "$1" in
        debug|release)       CONFIGURATION="$1"; shift ;;
        --with-android-vpn)  BUILD_ANDROID_VPN=1; shift ;;
        --firefox-xpi)
            if (( $# < 2 )) || [[ -z "$2" || "$2" == --* ]]; then
                echo "Usage: $0 [debug|release] [--with-android-vpn] [--firefox-xpi PATH]" >&2
                exit 2
            fi
            FIREFOX_XPI="$2"
            [[ "$FIREFOX_XPI" == /* ]] || FIREFOX_XPI="$PWD/$FIREFOX_XPI"
            shift 2
            ;;
        *) echo "Usage: $0 [debug|release] [--with-android-vpn] [--firefox-xpi PATH]" >&2; exit 2 ;;
    esac
done

cd "$ROOT"

echo "==> Building ($CONFIGURATION)"
swift build -c "$CONFIGURATION"
BIN_PATH="$(swift build -c "$CONFIGURATION" --show-bin-path)"

# Companions are generated, never checked in. Staging them here rather than trusting a
# leftover file in Resources/ is what keeps the bundle honest: a stale CLI or extension
# would otherwise ship silently, and neither shows up as a compile error.
echo "==> Building companions"
"$ROOT/Scripts/build-cli.sh" "$CONFIGURATION"
if [[ -n "$FIREFOX_XPI" ]]; then
    "$ROOT/Scripts/build-browser-extension.sh" --firefox-xpi "$FIREFOX_XPI"
else
    "$ROOT/Scripts/build-browser-extension.sh"
fi
if [[ "$BUILD_ANDROID_VPN" == 1 ]]; then
    "$ROOT/Scripts/build-android-vpn.sh" "$CONFIGURATION"
fi

APP="$ROOT/dist/ProxyMaxx.app"
echo "==> Bundling $APP"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS" "$APP/Contents/Resources"

cp "$BIN_PATH/ProxyMaxxApp" "$APP/Contents/MacOS/ProxyMaxx"
cp "$ROOT/Scripts/Info.plist" "$APP/Contents/Info.plist"
printf 'APPL????' > "$APP/Contents/PkgInfo"

# The app icon. CFBundleIconFile in Info.plist names AppIcon.icns, so it must sit
# directly in Contents/Resources.
echo "==> Copying app icon"
cp "$ROOT/Resources/icons/AppIcon.icns" "$APP/Contents/Resources/AppIcon.icns"

# Every `Resources/<language>.lproj/Localizable.strings` is a language the app can run in.
# English is the development region; adding a directory is all a new language needs.
echo "==> Copying localizations"
for lproj in "$ROOT"/Resources/*.lproj; do
    [[ -d "$lproj" ]] || continue
    cp -R "$lproj" "$APP/Contents/Resources/"
done

# The Android installer and its Magisk assets are read from Contents/Resources/Android at
# runtime, so they have to travel with the app rather than live only in the checkout.
echo "==> Copying Android resources"
rm -rf "$APP/Contents/Resources/Android"
mkdir -p "$APP/Contents/Resources/Android"
cp -R "$ROOT/Resources/android/." "$APP/Contents/Resources/Android/"
chmod +x "$APP/Contents/Resources/Android/"*.sh
if [[ ! -f "$APP/Contents/Resources/Android/proxymaxx-vpn.apk" ]]; then
    if [[ "$CONFIGURATION" == "release" ]]; then
        echo "❌ The release bundle is missing the Android tunnel APK." >&2
        echo "   Run Scripts/build-android-vpn.sh release, or Scripts/build-all.sh release." >&2
        exit 1
    fi
    echo "    note: no tunnel APK bundled — run Scripts/build-android-vpn.sh to add one"
fi

# The browser companion is two halves. The native messaging host must sit beside the app
# binary, because that is the path the host manifests point at. Chromium's unpacked
# extension and Firefox's XPI travel in Resources so the app can reveal them for installation.
echo "==> Copying browser companion"
if [[ -f "$BIN_PATH/proxymaxx-browser-host" ]]; then
    cp "$BIN_PATH/proxymaxx-browser-host" "$APP/Contents/MacOS/proxymaxx-browser-host"
    chmod +x "$APP/Contents/MacOS/proxymaxx-browser-host"
else
    echo "    note: the native messaging host was not built; the extension will run without the app bridge"
fi
rm -rf "$APP/Contents/Resources/Browser"
mkdir -p "$APP/Contents/Resources/Browser"
if [[ ! -f "$ROOT/Resources/browser/proxymaxx-extension/manifest.json" ||
      ! -f "$ROOT/Resources/browser/proxymaxx-firefox-extension.xpi" ]]; then
    echo "build-browser-extension.sh left a missing Chromium extension or Firefox XPI." >&2
    exit 1
fi
cp -R "$ROOT/Resources/browser/." "$APP/Contents/Resources/Browser/"

# The headless CLI ships inside the app so a terminal can drive the same engine as the
# window. It sits with the other bundled resources, at the path users are pointed to:
# ProxyMaxx.app/Contents/Resources/proxymaxx-cli.
echo "==> Copying command-line companion"
if [[ ! -f "$ROOT/Resources/proxymaxx-cli" ]]; then
    echo "❌ build-cli.sh left no binary to bundle." >&2
    exit 1
fi
cp "$ROOT/Resources/proxymaxx-cli" "$APP/Contents/Resources/proxymaxx-cli"
chmod +x "$APP/Contents/Resources/proxymaxx-cli"
# Sign the nested executable before sealing the bundle, so it keeps a valid
# signature after the app's own ad-hoc pass rewrites CodeResources.
codesign --force --sign - "$APP/Contents/Resources/proxymaxx-cli" >/dev/null 2>&1 || true

# Ad-hoc sign so macOS will launch it locally.
codesign --force --deep --sign - "$APP" >/dev/null 2>&1 || echo "    (ad-hoc signing skipped)"

# Everything above inspects staged sources, and a copy can still leave the bundle short
# or with a nested binary whose signature no longer matches. Assert the artifact itself,
# after sealing, so a broken bundle fails here instead of on someone's Mac.
echo "==> Verifying the bundle"
problems=()

check_present() {
    [[ -e "$APP/$1" ]] || problems+=("missing $1")
}

check_signature() {
    [[ -e "$APP/$1" ]] || return
    codesign --verify --strict "$APP/$1" >/dev/null 2>&1 || problems+=("invalid signature: $1")
}

check_present "Contents/MacOS/ProxyMaxx"
check_present "Contents/Resources/proxymaxx-cli"
check_present "Contents/Resources/Browser/proxymaxx-extension/manifest.json"
check_present "Contents/Resources/Browser/proxymaxx-firefox-extension.xpi"
check_present "Contents/Resources/Android/install_certificate_android_emulator.sh"
check_present "Contents/Resources/AppIcon.icns"
check_present "Contents/Resources/en.lproj/Localizable.strings"

# The browser bridge and the tunnel APK are optional only for debug builds: a release
# without them is a release with a companion the user was promised.
if [[ "$CONFIGURATION" == "release" ]]; then
    check_present "Contents/MacOS/proxymaxx-browser-host"
    check_present "Contents/Resources/Android/proxymaxx-vpn.apk"
fi

check_signature "Contents/MacOS/ProxyMaxx"
check_signature "Contents/MacOS/proxymaxx-browser-host"
check_signature "Contents/Resources/proxymaxx-cli"
codesign --verify --strict "$APP" >/dev/null 2>&1 || problems+=("invalid signature: ProxyMaxx.app seal")

if (( ${#problems[@]} > 0 )); then
    printf '❌ %s\n' "${problems[@]}" >&2
    exit 1
fi
echo "    all companions present; signatures valid"

echo "==> Done: $APP"
echo "    Open with: open \"$APP\""
