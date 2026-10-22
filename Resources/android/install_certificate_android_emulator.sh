#!/bin/bash -eu

#
# install_certificate_android_emulator.sh
# ProxyMaxx
#
# Installs the ProxyMaxx root certificate into an Android emulator's or device's system
# trust store, points its HTTP proxy at ProxyMaxx, and optionally installs and launches the
# ProxyMaxx tunnel app.
#
# Mirrors the contract of ProxyMaxx's equivalent script so the guide and the manual
# instructions agree: same flags, same modes, same root ladder.
#
# Written from scratch for ProxyMaxx. Runs on macOS's system bash (3.2) on purpose, so no
# bash 4 features are used.
#

mode=""
ip=""
port=""
proxymaxxCert=""
include_physical="false"
vpn_apk_path=""
socks_port="8989"
uninstall_vpn="false"
target_serial=""
enable_magisk="false"
restore_magisk="false"
magisk_script_path=""
magisk_apk_path=""
magisk_host_patch_path=""
magisk_state_dir=""
ADB_BIN=""
root_method=""
show_help="false"

# Must match the tunnel app in ProxyMaxx/Android.
VPN_PACKAGE="com.proxymaxx.vpn"
VPN_ACTIVITY="com.proxymaxx.vpn.MainActivity"

MODE_ALL="all"
MODE_PROXY="proxy"
MODE_REVERT="revertProxy"
MODE_CERTIFICATE="certificate"

while [[ $# -gt 0 ]]; do
    key="$1"
    case $key in
        -m|--mode)          mode="$2"; shift 2 ;;
        -i|--ip)            ip="$2"; shift 2 ;;
        -p|--port)          port="$2"; shift 2 ;;
        -c|--cert)          proxymaxxCert="$2"; shift 2 ;;
        --include-physical) include_physical="true"; shift ;;
        --vpn-apk)          vpn_apk_path="$2"; shift 2 ;;
        --socks-port)       socks_port="$2"; shift 2 ;;
        --uninstall-vpn)    uninstall_vpn="true"; shift ;;
        --serial)           target_serial="$2"; shift 2 ;;
        --enable-magisk)    enable_magisk="true"; shift ;;
        --restore-magisk)   restore_magisk="true"; shift ;;
        --magisk-script)    magisk_script_path="$2"; shift 2 ;;
        --magisk-apk)       magisk_apk_path="$2"; shift 2 ;;
        --magisk-host-patch) magisk_host_patch_path="$2"; shift 2 ;;
        --magisk-state-dir) magisk_state_dir="$2"; shift 2 ;;
        -h|--help)          show_help="true"; shift ;;
        *)
            echo "❌ Error: Unknown option '$1'"
            echo "Use -h or --help for usage information."
            exit 1
            ;;
    esac
done

print_usage() {
    cat <<'USAGE'
ProxyMaxx — Android certificate and proxy setup

Usage:
  install_certificate_android_emulator.sh -m <mode> [options]

Modes:
  all           Install the certificate, set the proxy, install and launch the tunnel app
  proxy         Set the proxy only (no certificate; system proxy only, no HTTPS decryption)
  certificate   Install the system certificate only
  revertProxy   Clear the proxy, uninstall the tunnel app and restore a Magisk session

Options:
  -m, --mode <mode>        One of the modes above (required)
  -i, --ip <address>       Address the device uses to reach this Mac
                           (10.0.2.2 for an emulator, the LAN address for a device)
  -p, --port <port>        ProxyMaxx HTTP proxy port
  -c, --cert <path>        Root certificate in PEM form
      --socks-port <port>  ProxyMaxx SOCKS5 port (default 8989)
      --vpn-apk <path>     Tunnel APK to install and launch
      --include-physical   Also process attached physical devices
      --serial <serial>    Only process this device
      --uninstall-vpn      Remove the tunnel app when reverting

Google Play AVDs (root must come from Magisk, because their adbd is production-signed):
      --enable-magisk          Allow the Magisk route
      --magisk-script <path>   Helper that patches and boots the AVD
      --magisk-apk <path>      Magisk APK
      --magisk-host-patch <p>  Upstream host_patch.sh
      --magisk-state-dir <p>   Where the helper keeps its session state
      --restore-magisk         Restore a Magisk session while reverting

  -h, --help               Show this help
USAGE
}

if [[ "$show_help" == "true" ]]; then
    print_usage
    exit 0
fi

if [[ -z "$mode" ]]; then
    echo "❌ Error: --mode is required."
    echo ""
    print_usage
    exit 1
fi

case "$mode" in
    "$MODE_ALL"|"$MODE_PROXY"|"$MODE_REVERT"|"$MODE_CERTIFICATE") ;;
    *)
        echo "❌ Error: Unknown mode '$mode'. Use all, proxy, certificate or revertProxy."
        exit 1
        ;;
esac

if [[ "$mode" == "$MODE_ALL" || "$mode" == "$MODE_PROXY" ]]; then
    [[ -n "$ip" ]] || { echo "❌ Error: --ip is required for mode '$mode'."; exit 1; }
    [[ -n "$port" ]] || { echo "❌ Error: --port is required for mode '$mode'."; exit 1; }
fi

if [[ "$mode" == "$MODE_ALL" || "$mode" == "$MODE_CERTIFICATE" ]]; then
    [[ -n "$proxymaxxCert" ]] || { echo "❌ Error: --cert is required for mode '$mode'."; exit 1; }
    [[ -f "$proxymaxxCert" ]] || { echo "❌ Error: Certificate not found: $proxymaxxCert"; exit 1; }
fi

# The hash is the file name the platform looks for, so both installing and reverting need it.
# Computing it here rather than inside the installer is what lets Revert name the file to remove.
CERT_HASH=""
if [[ -n "$proxymaxxCert" && -f "$proxymaxxCert" ]]; then
    CERT_HASH="$(openssl x509 -inform PEM -subject_hash_old -in "$proxymaxxCert" | head -1)"
fi

# ---------------------------------------------------------------------------
# adb
# ---------------------------------------------------------------------------

# Prefer Android Studio's SDK platform-tools so the emulator and this script share one adb
# server. A Homebrew adb can restart the server midway through setup and make a healthy
# emulator disappear.
checkADBCommand() {
    echo "Checking adb..."
    local candidate=""
    local sdk_candidate

    for sdk_candidate in \
        "${ANDROID_SDK_ROOT:-}" \
        "${ANDROID_HOME:-}" \
        "$HOME/Library/Android/sdk" \
        "$HOME/Android/Sdk"; do
        [[ -n "$sdk_candidate" ]] || continue
        if [[ -x "$sdk_candidate/platform-tools/adb" ]]; then
            candidate="$sdk_candidate/platform-tools/adb"
            break
        fi
    done

    # `type -P` resolves the executable without matching a shell function named adb.
    if [[ -z "$candidate" ]]; then
        sdk_candidate="$(type -P adb 2>/dev/null || true)"
        if [[ -n "$sdk_candidate" && -x "$sdk_candidate" ]]; then
            candidate="$sdk_candidate"
        fi
    fi

    if [[ -z "$candidate" ]]; then
        for sdk_candidate in /opt/homebrew/bin/adb /usr/local/bin/adb; do
            if [[ -x "$sdk_candidate" ]]; then
                candidate="$sdk_candidate"
                break
            fi
        done
    fi

    if [[ -z "$candidate" ]]; then
        echo ""
        echo "❌ adb was not found."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Install Android SDK Platform-Tools (Android Studio → Settings → Android SDK →"
        echo "SDK Tools → Android SDK Platform-Tools), start an emulator, then run this again."
        echo ""
        exit 1
    fi

    ADB_BIN="$candidate"
    echo "✅ adb: $ADB_BIN"
}

# Every adb call goes through the single executable chosen above, with stdin detached:
# adb forwards this shell's input to `adb shell`, which would swallow a piped consent answer.
run_adb() {
    "$ADB_BIN" "$@" </dev/null
}

# The callers that pipe a heredoc to the device keep the caller's standard input.
run_adb_with_stdin() {
    "$ADB_BIN" "$@"
}

connected_devices() {
    run_adb devices 2>/dev/null | awk 'NR > 1 && $2 == "device" { print $1 }'
}

checkDeviceStatusFunc() {
    echo "1. Checking for devices..."

    local adb_devices_output
    if ! adb_devices_output="$(run_adb devices 2>&1)"; then
        echo ""
        echo "❌ adb failed to list devices."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "adb: $ADB_BIN"
        [[ -n "$adb_devices_output" ]] && echo "$adb_devices_output"
        echo "Restart the emulator and try again."
        echo ""
        exit 1
    fi

    local found
    found="$(connected_devices)"

    if [[ -z "$found" ]]; then
        echo ""
        echo "❌ No device or emulator is connected."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "1) Open Android Studio → Tools → Device Manager"
        echo "2) Start an emulator and wait for it to finish booting"
        echo "3) Run this again"
        echo ""
        echo "Verify with: adb devices"
        echo ""
        exit 1
    fi

    if [[ -n "$target_serial" ]] && ! printf '%s\n' "$found" | grep -Fxq "$target_serial"; then
        echo ""
        echo "❌ '$target_serial' is not connected."
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "Start that emulator, or drop --serial to use every connected device."
        echo ""
        exit 1
    fi

    echo "✅ Found: $(printf '%s' "$found" | tr '\n' ' ')"
}

should_process_device() {
    local device_id="$1"
    local include_physical_flag="$2"
    local is_emulator="false"

    [[ "$device_id" == *"emulator"* ]] && is_emulator="true"

    if [[ -n "$target_serial" && "$device_id" != "$target_serial" ]]; then
        return 1
    elif [[ "$include_physical_flag" == "true" ]]; then
        return 0
    elif [[ "$is_emulator" == "true" ]]; then
        return 0
    else
        return 1
    fi
}

get_device_type_string() {
    if [[ "$1" == *"emulator"* ]]; then
        echo "Emulator"
    else
        echo "Device"
    fi
}

# ---------------------------------------------------------------------------
# root
# ---------------------------------------------------------------------------

print_root_required_help() {
    echo ""
    echo "💡 Recovery options:"
    if [[ "$enable_magisk" != "true" ]]; then
        echo "   • Turn on “Support Google Play AVDs with Magisk” in the Android Emulator"
        echo "     guide, then run the one-click setup again."
    fi
    echo "   • Or create an emulator from a system image labelled “Google APIs” (without"
    echo "     Play Store), which allows adb root:"
    echo "       1) Android Studio → Tools → Device Manager → Create Device"
    echo "       2) Pick a system image labelled “Google APIs”"
    echo "       3) Start it and run this again"
    echo ""
    echo "   Why root is needed: installing a system CA means mounting over the system CA"
    echo "   directory, which no unprivileged process may do. Play Store images ship a"
    echo "   production-signed adbd, so adb root is not available there."
    echo ""
    echo "   Alternative: run with -m proxy, which sets the proxy without installing a"
    echo "   certificate. HTTP is still captured; HTTPS is not decrypted."
    echo ""
}

device_has_working_su() {
    local device="$1"
    local uid
    # Magisk exposes su from /debug_ramdisk before its applet path exists, so check both.
    uid="$(run_adb -s "$device" shell 'PATH=$PATH:/debug_ramdisk su -c "id -u"' 2>/dev/null | tr -d '\r\n' || true)"
    [[ "$uid" == "0" ]]
}

prepare_root_method() {
    local device="$1"
    local device_type="$2"
    root_method=""

    if device_has_working_su "$device"; then
        root_method="su"
        echo "✅ Root available (su) on $device"
        return 0
    fi

    local adb_root_output
    adb_root_output="$(run_adb -s "$device" root 2>&1 || true)"
    run_adb -s "$device" wait-for-device
    local device_uid
    device_uid="$(run_adb -s "$device" shell id -u 2>/dev/null | tr -d '\r\n' || true)"
    if [[ "$device_uid" == "0" ]]; then
        root_method="adb"
        echo "✅ Root available (adb root) on $device"
        return 0
    fi

    if [[ "$device" != emulator-* ]]; then
        echo "❌ $device_type $device does not expose working root access."
        echo "   The automatic Magisk route is limited to Android Studio AVDs on purpose."
        echo "   $adb_root_output"
        print_root_required_help
        return 1
    fi

    if [[ "$enable_magisk" != "true" ]]; then
        echo "❌ adb root is unavailable on $device."
        echo "   That normally means a Google Play system image."
        echo "   $adb_root_output"
        print_root_required_help
        return 1
    fi

    if [[ ! -f "$magisk_script_path" || ! -f "$magisk_apk_path" || ! -f "$magisk_host_patch_path" ]]; then
        echo "❌ PM-MAGISK-RESOURCE-001: the bundled Magisk resources are missing."
        echo "   Expected:"
        echo "     script:     $magisk_script_path"
        echo "     apk:        $magisk_apk_path"
        echo "     host patch: $magisk_host_patch_path"
        echo "   Reinstall ProxyMaxx, or build the bundle with Scripts/bundle-app.sh."
        return 1
    fi

    echo ""
    echo "🔐 adb root is unavailable. Starting the consent-based Play Store AVD setup…"
    echo "   This patches the emulator's ramdisk with Magisk for this boot only. The"
    echo "   installed system image and the AVD configuration are not modified."

    local helper_arguments
    helper_arguments=(--mode root --serial "$device" --adb "$ADB_BIN" \
        --magisk-apk "$magisk_apk_path" --host-patch "$magisk_host_patch_path")
    if [[ -n "$magisk_state_dir" ]]; then
        helper_arguments+=(--state-dir "$magisk_state_dir")
    fi

    if ! bash "$magisk_script_path" "${helper_arguments[@]}"; then
        echo "❌ Magisk could not prepare $device."
        echo "   Review the output above, then try again."
        return 1
    fi

    run_adb -s "$device" wait-for-device
    if ! device_has_working_su "$device"; then
        echo "❌ Magisk finished but $device still has no root."
        echo "   Restart the emulator and run the setup again."
        return 1
    fi

    root_method="su"
    return 0
}

restore_magisk_root_if_needed() {
    [[ "$restore_magisk" == "true" ]] || return 0

    if [[ ! -f "$magisk_script_path" ]]; then
        echo "❌ The bundled Magisk restore helper is missing."
        echo "   Reinstall ProxyMaxx and try reverting again."
        return 1
    fi

    local found_rooted_emulator="false"
    local device
    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        # Only Android Studio AVDs are managed this way; physical devices use their own
        # root controls and are never patched.
        [[ "$device" == emulator-* ]] || continue
        device_has_working_su "$device" || continue
        found_rooted_emulator="true"

        echo ""
        echo "🔄 Checking $device for an active Magisk session…"
        local helper_arguments
        helper_arguments=(--mode restore-if-needed --serial "$device" --adb "$ADB_BIN")
        if [[ -n "$magisk_state_dir" ]]; then
            helper_arguments+=(--state-dir "$magisk_state_dir")
        fi

        local helper_status=0
        if bash "$magisk_script_path" "${helper_arguments[@]}"; then
            helper_status=0
        else
            helper_status="$?"
        fi

        if [[ "$helper_status" == "10" ]]; then
            echo "⚠️  The proxy was reverted, but restoring the emulator was cancelled."
            return 10
        elif [[ "$helper_status" != "0" ]]; then
            echo "❌ Could not return $device to a stock boot."
            return "$helper_status"
        fi
    done

    if [[ "$found_rooted_emulator" != "true" ]]; then
        echo "ℹ️  No active Magisk session was found."
    fi
    return 0
}

run_script_as_root() {
    local device="$1"
    local remote_script="$2"
    local argument="${3:-}"
    if [[ "$root_method" == "su" ]]; then
        run_adb -s "$device" shell "PATH=\$PATH:/debug_ramdisk su -c 'sh $remote_script $argument'"
    else
        run_adb -s "$device" shell "sh $remote_script $argument"
    fi
}

run_command_as_root() {
    local device="$1"
    local command="$2"
    if [[ "$root_method" == "su" ]]; then
        run_adb -s "$device" shell "PATH=\$PATH:/debug_ramdisk su -c '$command'"
    else
        run_adb -s "$device" shell "$command"
    fi
}

force_stop_as_root() {
    local device="$1"
    local package="$2"
    if [[ "$root_method" == "su" ]]; then
        run_adb -s "$device" shell "PATH=\$PATH:/debug_ramdisk su -c 'am force-stop $package'" >/dev/null 2>&1 || true
    else
        run_adb -s "$device" shell "am force-stop $package" >/dev/null 2>&1 || true
    fi
}

# The user store would otherwise stay trusted across every reboot; the system store is a tmpfs
# that a reboot clears anyway.
removeCertificateFromDevice() {
    local device="$1"
    [[ -n "$CERT_HASH" ]] || return 0

    # Removal and the check that follows it run in the same privileged command: the store is
    # unreadable to the shell user, so a separate check would report success either way.
    local removal="rm -f /data/misc/user/0/cacerts-added/$CERT_HASH.0 \
/data/misc/keychain/cacerts-added/$CERT_HASH.0 \
/system/etc/security/cacerts/$CERT_HASH.0; \
! test -f /data/misc/user/0/cacerts-added/$CERT_HASH.0 \
-o -f /data/misc/keychain/cacerts-added/$CERT_HASH.0"

    # Revert never goes through root preparation, so root is checked here rather than assumed.
    if [[ "$root_method" == "su" ]] || device_has_working_su "$device"; then
        run_adb -s "$device" shell "PATH=\$PATH:/debug_ramdisk su -c '$removal'" >/dev/null 2>&1
    else
        run_command_as_root "$device" "$removal" >/dev/null 2>&1
    fi
}

# ---------------------------------------------------------------------------
# tunnel app
# ---------------------------------------------------------------------------

installVpnApk() {
    if [[ -z "$vpn_apk_path" || ! -f "$vpn_apk_path" ]]; then
        return 0
    fi

    echo ""
    echo "4. Installing the ProxyMaxx tunnel app…"

    local device
    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        local device_type
        device_type="$(get_device_type_string "$device")"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🤖 $device_type: $device"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        if run_adb -s "$device" install -r "$vpn_apk_path" 2>&1; then
            echo "✅ Tunnel app installed"
        else
            echo "⚠️  The tunnel app may not have installed; continuing."
        fi
    done
}

launchVpnApp() {
    if [[ -z "$vpn_apk_path" ]]; then
        return 0
    fi

    echo ""
    echo "5. Launching the tunnel app…"

    local device
    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        local device_type
        device_type="$(get_device_type_string "$device")"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🚀 $device_type: $device"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # The proxy details travel as intent extras, so the app is configured before it
        # is even shown. These extra names are the tunnel's own contract. `auto_start` asks
        # the app to connect on its own, which leaves the system's consent prompt as the only
        # thing between the install and a captured flow.
        if run_adb -s "$device" shell am start -n "$VPN_PACKAGE/$VPN_ACTIVITY" \
            --es proxy_host "$ip" \
            --ei socks_port "$socks_port" \
            --ei http_port "$port" \
            --ez auto_start true 2>&1; then
            echo "✅ Launched"
            echo ""
            echo "📱 Accept the prompts on the emulator — the tunnel connects itself."
        else
            echo "⚠️  Could not launch the tunnel app."
        fi
    done
}

uninstallVpnApk() {
    [[ "$uninstall_vpn" == "true" ]] || return 0

    echo ""
    echo "3. Removing the tunnel app…"

    local device
    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        local device_type
        device_type="$(get_device_type_string "$device")"

        # adb reports failure here even when the removal succeeded — a running app is killed
        # asynchronously, and the exit code follows the first attempt. So the outcome is
        # checked rather than the exit code, and the reason is shown if it really did fail.
        run_adb -s "$device" uninstall "$VPN_PACKAGE" >/dev/null 2>&1 || true
        if [[ -z "$(run_adb -s "$device" shell pm path "$VPN_PACKAGE" 2>/dev/null | tr -d '\r')" ]]; then
            echo "✅ Removed from $device_type $device"
        else
            echo "⚠️  The tunnel app is still installed on $device_type $device"
            run_adb -s "$device" uninstall "$VPN_PACKAGE" 2>&1 || true
        fi
    done
}

# ---------------------------------------------------------------------------
# certificate
# ---------------------------------------------------------------------------

injectCertificateFunc() {
    echo "3. Installing the ProxyMaxx certificate as a system CA…"

    if [[ -z "$CERT_HASH" ]]; then
        echo "❌ Could not compute the certificate hash."
        exit 1
    fi

    local any_failed="false"
    local device

    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        local device_type
        device_type="$(get_device_type_string "$device")"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🤖 $device_type: $device"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        # Magisk preparation cold-boots Play Store AVDs. Establish the final root session
        # before uploading anything, because that restart can clear /data/local/tmp.
        if ! prepare_root_method "$device" "$device_type"; then
            any_failed="true"
            continue
        fi

        # A fresh boot can report sys.boot_completed slightly before adbd is ready for file
        # transfer, so retry this harmless copy instead of failing the whole run.
        local pushed="false" push_error=""
        for _ in 1 2 3 4 5; do
            if push_error="$(run_adb -s "$device" push "$proxymaxxCert" "/data/local/tmp/$CERT_HASH.0" 2>&1)"; then
                pushed="true"
                break
            fi
            sleep 2
        done
        if [[ "$pushed" != "true" ]]; then
            echo "❌ Could not push the certificate to $device"
            [[ -n "$push_error" ]] && echo "   $push_error"
            any_failed="true"
            continue
        fi

        local INJECTION_SCRIPT="/data/local/tmp/proxymaxx_inject_cert.sh"
        cat << 'REMOTE' | run_adb_with_stdin -s "$device" shell "cat > $INJECTION_SCRIPT"
#!/system/bin/sh
# Runs on the device as root.
#
# An app with its own network-security-config trusts only the system store, so the CA has to be
# there; the user store alone is rejected with "Trust anchor for certification path not found".
set -e

CERT_FILE="$1"
if [ -z "$CERT_FILE" ] || [ ! -s "$CERT_FILE" ]; then
    echo "❌ Certificate payload missing or empty"
    exit 1
fi

CERT_NAME="${CERT_FILE##*/}"

if [ -d "/apex/com.android.conscrypt/cacerts" ]; then
    CERT_SOURCE="/apex/com.android.conscrypt/cacerts"
elif [ -d "/system/etc/security/cacerts" ]; then
    CERT_SOURCE="/system/etc/security/cacerts"
elif [ -d "/system/etc/certificates" ]; then
    CERT_SOURCE="/system/etc/certificates"
elif [ -d "/etc/security/cacerts" ]; then
    CERT_SOURCE="/etc/security/cacerts"
else
    echo "❌ No system certificate directory found"
    exit 1
fi

echo "📂 Certificate source: $CERT_SOURCE"

mkdir -p -m 700 /data/local/tmp/tmp-ca-copy
cp "$CERT_SOURCE"/* /data/local/tmp/tmp-ca-copy/ 2>/dev/null || true

mkdir -p /system/etc/security/cacerts
mount -t tmpfs tmpfs /system/etc/security/cacerts

mv /data/local/tmp/tmp-ca-copy/* /system/etc/security/cacerts/ 2>/dev/null || true

# Move only our own hashed file, so other tools' CAs in /data/local/tmp are left alone.
mv "$CERT_FILE" /system/etc/security/cacerts/

chown root:root /system/etc/security/cacerts/*
chmod 644 /system/etc/security/cacerts/*
chcon u:object_r:system_file:s0 /system/etc/security/cacerts/*

# Zygote forks every app, so binding there covers future processes; the loop below covers the
# ones already running.
ZYGOTE_PID=$(pidof zygote || true)
ZYGOTE64_PID=$(pidof zygote64 || true)

for Z_PID in "$ZYGOTE_PID" "$ZYGOTE64_PID"; do
    if [ -n "$Z_PID" ]; then
        nsenter --mount=/proc/$Z_PID/ns/mnt -- \
            mount --bind /system/etc/security/cacerts "$CERT_SOURCE" || true
    fi
done

APP_PIDS=$(
    echo "$ZYGOTE_PID $ZYGOTE64_PID" | \
    xargs -n1 ps -o 'PID' -P | \
    grep -v PID
)

for PID in $APP_PIDS; do
    nsenter --mount=/proc/$PID/ns/mnt -- \
        mount --bind /system/etc/security/cacerts "$CERT_SOURCE" &
done
wait || true

# Also the user store: Chrome consults it, and unlike the tmpfs it survives a reboot.
for USER_STORE in /data/misc/user/0/cacerts-added /data/misc/keychain/cacerts-added; do
    [ -d "${USER_STORE%/*}" ] || continue
    mkdir -p "$USER_STORE"
    cp "/system/etc/security/cacerts/$CERT_NAME" "$USER_STORE/$CERT_NAME"
    chown system:system "$USER_STORE/$CERT_NAME"
    chmod 644 "$USER_STORE/$CERT_NAME"
done

echo "✅ Certificate installed into the system store"
REMOTE

        if ! run_adb -s "$device" shell "chmod +x $INJECTION_SCRIPT"; then
            echo "❌ Could not make the injection script executable on $device"
            any_failed="true"
            continue
        fi

        if ! run_script_as_root "$device" "$INJECTION_SCRIPT" "/data/local/tmp/$CERT_HASH.0"; then
            echo "❌ Installing the certificate failed on $device"
            echo "   Root was available but writing the trust store failed."
            any_failed="true"
            continue
        fi

        # The system store is the one that matters; it is the tmpfs in the init namespace, which
        # the root shell can read directly.
        if ! run_command_as_root "$device" "test -f /system/etc/security/cacerts/$CERT_HASH.0"; then
            echo "❌ The certificate is not in the system store after installation on $device"
            echo "   Without it, any app that trusts only the system store rejects the tunnel."
            any_failed="true"
            continue
        fi

        # Chrome does not consult the system store for an intercepted leaf in every case, so
        # the leaf's public key is additionally pinned through Chrome's own command line.
        # This also covers WebView and content-shell.
        local SPKI_FINGERPRINT
        SPKI_FINGERPRINT="$(openssl x509 -in "$proxymaxxCert" -pubkey -noout | \
            openssl pkey -pubin -outform der | \
            openssl dgst -sha256 -binary | \
            base64)"

        local CHROME_FLAGS_SCRIPT="/data/local/tmp/proxymaxx_chrome_flags.sh"
        cat << REMOTE | run_adb_with_stdin -s "$device" shell "cat > $CHROME_FLAGS_SCRIPT"
#!/system/bin/sh
FLAGS="chrome --ignore-certificate-errors-spki-list=$SPKI_FINGERPRINT"

for variant in chrome android-webview webview content-shell; do
    for base_path in /data/local /data/local/tmp; do
        FLAGS_PATH=\$base_path/\$variant-command-line
        echo "\$FLAGS" > "\$FLAGS_PATH"
        chmod 744 "\$FLAGS_PATH"
        chcon "u:object_r:shell_data_file:s0" "\$FLAGS_PATH"
    done
done
REMOTE

        if ! run_adb -s "$device" shell "chmod +x $CHROME_FLAGS_SCRIPT"; then
            echo "❌ Could not make the Chrome flags script executable on $device"
            any_failed="true"
            continue
        fi

        if ! run_script_as_root "$device" "$CHROME_FLAGS_SCRIPT"; then
            echo "❌ Could not apply the Chrome flags on $device"
            any_failed="true"
            continue
        fi

        force_stop_as_root "$device" "com.android.chrome"

        # Restart everything so the new namespace mounts are picked up. The tunnel app is
        # deliberately spared, since stopping it would drop the tunnel.
        local apps app
        apps="$(run_adb -s "$device" shell dumpsys window a 2>/dev/null | grep "/" | cut -d "{" -f2 | cut -d "/" -f1 | cut -d " " -f2 || true)"
        for app in $apps; do
            if [[ "$app" != "$VPN_PACKAGE" ]]; then
                run_adb -s "$device" shell am force-stop "$app" >/dev/null 2>&1 || true
            fi
        done

        echo "✅ Certificate installed on $device_type $device"
    done

    if [[ "$any_failed" == "true" ]]; then
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# proxy
# ---------------------------------------------------------------------------

overrideProxy() {
    # The tunnel already carries every app's TCP, so pointing the device at the HTTP proxy as
    # well would make the proxy's own address the first hop the tunnel has to relay. That hop
    # cannot bootstrap itself, and the browser reports ERR_TUNNEL_CONNECTION_FAILED. It is one
    # or the other, never both: with the tunnel, no proxy setting is needed.
    if [[ -n "$vpn_apk_path" ]]; then
        echo "2. Clearing the HTTP proxy — the tunnel carries all traffic instead."

        local device
        for device in $(connected_devices); do
            should_process_device "$device" "$include_physical" || continue
            local device_type
            device_type="$(get_device_type_string "$device")"

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🤖 $device_type: $device"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            # A proxy left over from an earlier run sits on the tunnel path, so the tunnel
            # would have to relay the proxy's own address to reach the proxy. The device then
            # reports "No internet access" while every flow goes nowhere.
            if run_adb -s "$device" shell settings put global http_proxy :0; then
                echo "✅ Proxy cleared"
            else
                echo "⚠️  Could not clear the proxy; a stale setting may still be on the tunnel path"
            fi
        done
        echo ""
        return 0
    fi

    echo "2. Setting the HTTP proxy to ${ip}:${port}…"

    local device
    for device in $(connected_devices); do
        should_process_device "$device" "$include_physical" || continue
        local device_type
        device_type="$(get_device_type_string "$device")"

        echo ""
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
        echo "🤖 $device_type: $device"
        echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

        run_adb -s "$device" shell svc wifi enable >/dev/null 2>&1 || true
        if run_adb -s "$device" shell settings put global http_proxy "$ip:$port"; then
            echo "✅ Proxy set"
        else
            echo "❌ Could not set the proxy"
        fi
    done
    echo ""
}

revertProxy() {
    echo "2. Clearing the HTTP proxy and the certificate…"

    local device
    for device in $(connected_devices); do
        if should_process_device "$device" "$include_physical"; then
            local device_type
            device_type="$(get_device_type_string "$device")"

            echo ""
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "🤖 $device_type: $device"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"

            if run_adb -s "$device" shell settings put global http_proxy :0; then
                echo "✅ Proxy cleared"
            else
                echo "❌ Could not clear the proxy"
            fi

            if removeCertificateFromDevice "$device"; then
                echo "✅ Certificate removed"
            else
                echo "⚠️  The certificate is still trusted on this device"
                echo "   Remove it under Settings → Security → Encryption & credentials →"
                echo "   Trusted credentials → User."
            fi
        fi
    done
    echo ""

    uninstallVpnApk

    # adb-root devices need no restoration: nothing about their boot was changed. A Magisk
    # session did change the boot, so it is offered its own restore.
    restore_magisk_root_if_needed
}

# ---------------------------------------------------------------------------
# messages
# ---------------------------------------------------------------------------

print_success_message() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Done"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    echo "📝 Next steps:"
    echo "   1. Restart your app from Android Studio"
    echo "   2. Watch the traffic in ProxyMaxx"
    echo ""
}

print_success_message_with_vpn() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Done"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo ""
    if [[ -n "$vpn_apk_path" ]]; then
        echo "📝 Next steps:"
        echo "   1. The tunnel app should now be open on your emulator"
        echo "   2. Tap Connect"
        echo "   3. Restart your app from Android Studio"
        echo ""
        echo "💡 The tunnel captures every app's traffic, including Flutter and React Native"
        echo "   apps that ignore the system proxy."
        echo ""
    else
        print_success_message
    fi
}

installVpnOnlyHelper() {
    installVpnApk
    launchVpnApp
    print_success_message_with_vpn
}

# ---------------------------------------------------------------------------
# main
# ---------------------------------------------------------------------------

checkADBCommand
checkDeviceStatusFunc

case "$mode" in
    "$MODE_ALL")
        # Certificate and root preparation run first: on a Play Store AVD the Magisk route
        # cold-boots the emulator, and declining it should leave the device untouched.
        if injectCertificateFunc; then
            overrideProxy
            installVpnOnlyHelper
        else
            echo ""
            echo "❌ Setup failed on one or more devices"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            exit 1
        fi
        ;;
    "$MODE_PROXY")
        if [[ -n "$vpn_apk_path" ]]; then
            overrideProxy
            installVpnOnlyHelper
        else
            overrideProxy
            print_success_message
        fi
        ;;
    "$MODE_REVERT")
        revert_status=0
        if revertProxy; then
            revert_status=0
        else
            revert_status="$?"
        fi
        echo ""
        if [[ "$revert_status" == "0" ]]; then
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "✅ Revert complete"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
        else
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo "❌ Revert incomplete"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            echo "The proxy and tunnel app were cleared, but the Magisk session was not"
            echo "restored. Review the output above and try Revert again."
            echo ""
            exit "$revert_status"
        fi
        ;;
    "$MODE_CERTIFICATE")
        if injectCertificateFunc; then
            print_success_message
        else
            echo ""
            echo "❌ Installation failed on one or more devices"
            echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
            echo ""
            exit 1
        fi
        ;;
esac

exit 0
