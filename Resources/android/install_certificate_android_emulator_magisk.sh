#!/bin/bash

#
# install_certificate_android_emulator_magisk.sh
# ProxyMaxx
#
# Temporarily boots an Android Studio Google Play AVD with a Magisk-patched ramdisk, so the
# system CA directory can be mounted over. The installed SDK image and the AVD configuration
# are never modified, and Quick Boot snapshots are neither loaded nor saved.
#
# Play Store AVDs ship a production-signed adbd, so `adb root` is unavailable on them. AVDs
# built from a "Google APIs" image do not need this script at all.
#
# Written from scratch for ProxyMaxx against the documented Magisk flow. Runs on macOS's
# system bash (3.2), so no bash 4 features are used.
#

set -Eeuo pipefail

readonly SCRIPT_VERSION="1"
readonly MAGISK_VERSION="30.7"

# Upstream Magisk artifacts — unmodified, so these are the published release digests.
readonly MAGISK_APK_SHA256="e0d32d2123532860f97123d927b1bb86c4e08e6fd8a48bfc6b5bee0afae9ebd5"
readonly MAGISK_HOST_PATCH_SHA256="1720669a684f75fe90a7318868dd4528f2e736a5ad5363f92a3c51c848d79703"

# ProxyMaxx-owned glue. These are what make the boot grant adb-shell root and nothing else.
readonly BOOTSTRAP_RC_SHA256="56a6fd526756225caf3440a735a25080d1767486413d31cb7f592fbfb98dd63c"
readonly BOOTSTRAP_SCRIPT_SHA256="938801f6f64f5fae075f6c5d714aab5c7aa6e55d4174262c7c7446c0aff880e5"
readonly BOOTSTRAP_INJECTOR_SHA256="5a1388a1531874a72b6b8405f615b4ca56e79befa336bce1cbed60b8ff3138dd"

# Magisk's volatile ramdisk directory. Anything here disappears on a stock boot, which is
# exactly what makes it a trustworthy record of "this session was ours".
readonly SESSION_MARKER="/debug_ramdisk/.proxymaxx-magisk-session"
readonly POLICY_READY_MARKER="/debug_ramdisk/.proxymaxx-magisk-policy-ready"
readonly BOOTSTRAP_LOG="/debug_ramdisk/proxymaxx-magisk-bootstrap.log"
readonly BOOTSTRAP_RUNTIME="/debug_ramdisk/proxymaxx_magisk_bootstrap.sh"

mode="root"
serial=""
adb_bin=""
emulator_bin=""
sdk_root=""
avd_home=""
magisk_apk=""
host_patch_script=""
bootstrap_rc=""
bootstrap_script=""
bootstrap_injector=""
state_dir=""
result_file=""

phase="arguments"
support_id="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
log_file=""
work_dir=""
remote_work_created="false"
rooted_launch_started="false"
operation_complete="false"
rollback_attempted="false"
rollback_succeeded="false"
policy_restore_succeeded="false"
emulator_pid=""

avd_name=""
avd_dir=""
config_file=""
image_dir=""
source_image=""
patched_image=""
api_level=""
abi=""
page_size=""
package_revision=""
platform=""
play_store_config="false"
play_store_package="false"
console_port=""

print_usage() {
    cat <<'USAGE'
Usage:
  install_certificate_android_emulator_magisk.sh --mode <root|restore|restore-if-needed|diagnose> \
    --serial <adb-serial> [options]

Required for root mode:
  --serial <serial>             Target exactly one running emulator
  --magisk-apk <path>           Bundled Magisk APK
  --host-patch <path>           Bundled Magisk host_patch.sh

Options:
  --adb <path>                  Android SDK adb executable
  --emulator <path>             Android SDK emulator executable
  --sdk-root <path>             Android SDK root
  --avd-home <path>             Android AVD home directory
  --state-dir <path>            ProxyMaxx-owned state and log directory
  --result-file <path>          Machine-readable result output
  -h, --help                    Show this help

`restore-if-needed` changes nothing unless it finds an active ProxyMaxx-created Magisk
session for the exact AVD and the user confirms the stock restart. Physical devices are never
patched, and installed SDK system images are never overwritten.
USAGE
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --mode)        mode="${2:-}"; shift 2 ;;
        --serial)      serial="${2:-}"; shift 2 ;;
        --adb)         adb_bin="${2:-}"; shift 2 ;;
        --emulator)    emulator_bin="${2:-}"; shift 2 ;;
        --sdk-root)    sdk_root="${2:-}"; shift 2 ;;
        --avd-home)    avd_home="${2:-}"; shift 2 ;;
        --magisk-apk)  magisk_apk="${2:-}"; shift 2 ;;
        --host-patch)  host_patch_script="${2:-}"; shift 2 ;;
        --state-dir)   state_dir="${2:-}"; shift 2 ;;
        --result-file) result_file="${2:-}"; shift 2 ;;
        -h|--help)     print_usage; exit 0 ;;
        *) echo "Unknown argument: $1" >&2; print_usage >&2; exit 2 ;;
    esac
done

write_result() {
    local status="$1"
    local error_code="${2:-}"
    local message="${3:-}"

    [[ -n "$result_file" ]] || return 0

    local result_parent
    result_parent="$(dirname "$result_file")"
    mkdir -p -m 700 "$result_parent"
    local temporary_result="${result_file}.tmp.$$"
    {
        printf 'status=%s\n' "$status"
        printf 'phase=%s\n' "$phase"
        printf 'error_code=%s\n' "$error_code"
        printf 'message=%s\n' "${message//$'\n'/ }"
        printf 'support_id=%s\n' "$support_id"
        printf 'log_file=%s\n' "$log_file"
        printf 'serial=%s\n' "$serial"
        printf 'avd_name=%s\n' "$avd_name"
        printf 'api_level=%s\n' "$api_level"
        printf 'abi=%s\n' "$abi"
        printf 'platform=%s\n' "$platform"
        printf 'magisk_version=%s\n' "$MAGISK_VERSION"
        printf 'rollback_attempted=%s\n' "$rollback_attempted"
        printf 'rollback_succeeded=%s\n' "$rollback_succeeded"
        printf 'policy_restore_succeeded=%s\n' "$policy_restore_succeeded"
    } > "$temporary_result"
    chmod 600 "$temporary_result"
    mv -f "$temporary_result" "$result_file"
}

print_header() {
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "🔐 ProxyMaxx — Google Play AVD setup with Magisk"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Script version : $SCRIPT_VERSION"
    echo "Support ID     : $support_id"
    echo ""
}

print_failure() {
    local error_id="$1"
    local message="$2"
    local guidance="$3"

    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "❌ ProxyMaxx could not prepare this emulator"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "Error ID : $error_id"
    echo "Stage    : $phase"
    echo "Reason   : $message"
    if [[ "$rollback_attempted" == "true" ]]; then
        echo "Rollback : $rollback_succeeded"
    else
        echo "Changes  : No persistent Android SDK image changes were made"
    fi
    echo ""
    echo "What to try:"
    printf '%b\n' "$guidance"
    echo ""
    [[ -z "$log_file" ]] || echo "Diagnostic log: $log_file"
    echo "Support ID    : $support_id"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
}

fail() {
    local exit_code="$1"
    local error_id="$2"
    local message="$3"
    local guidance="$4"
    local failed_phase="$phase"

    set +e
    # A rooted boot that never completed must not be left behind: the whole point of the
    # session is that it is temporary.
    if [[ "$rooted_launch_started" == "true" && "$operation_complete" != "true" ]]; then
        rollback_to_stock || true
    fi
    phase="$failed_phase"
    print_failure "$error_id" "$message" "$guidance"
    write_result "failed" "$error_id" "$message"
    exit "$exit_code"
}

cleanup() {
    set +e
    [[ -n "$remote_work_created" && "$remote_work_created" == "true" ]] || return 0
    "$adb_bin" -s "$serial" shell -n rm -f \
        /data/local/tmp/busybox \
        /data/local/tmp/magisk.apk \
        /data/local/tmp/proxymaxx_host_patch.sh \
        /data/local/tmp/proxymaxx_magisk_bootstrap.rc \
        /data/local/tmp/proxymaxx_magisk_bootstrap.sh \
        /data/local/tmp/proxymaxx_magisk_inject_bootstrap.sh \
        /data/local/tmp/proxymaxx_ramdisk.img \
        /data/local/tmp/proxymaxx_ramdisk.img.magisk \
        /data/local/tmp/proxymaxx_ramdisk.img.magisk.proxymaxx.cpio \
        /data/local/tmp/proxymaxx_ramdisk.img.magisk.proxymaxx \
        >/dev/null 2>&1 || true
    [[ -z "$work_dir" ]] || rm -rf "$work_dir"
    return 0
}

handle_signal() {
    set +e
    if [[ "$rooted_launch_started" == "true" && "$operation_complete" != "true" ]]; then
        echo ""
        echo "↩️  Interrupted — restoring the emulator…"
        rollback_to_stock || true
    fi
    write_result "interrupted" "PM-MAGISK-SIGNAL-001" "The setup was interrupted."
    cleanup
    exit 130
}

sanitize_component() {
    printf '%s' "$1" | tr -c 'A-Za-z0-9._-' '_'
}

property_value() {
    local file="$1"
    local key="$2"

    # Android Emulator rewrites config.ini, sometimes with spaces around the equals sign.
    awk -F= -v requested_key="$key" '
        {
            current_key = $1
            gsub(/^[[:space:]]+|[[:space:]]+$/, "", current_key)
            if (current_key == requested_key) {
                value = substr($0, index($0, "=") + 1)
                gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
                print value
                exit
            }
        }
    ' "$file" | tr -d '\r'
}

sha256_file() {
    shasum -a 256 "$1" | awk '{print $1}'
}

resolve_tools() {
    phase="tool_discovery"

    if [[ -z "$adb_bin" ]]; then
        if [[ -n "${ANDROID_SDK_ROOT:-}" && -x "${ANDROID_SDK_ROOT}/platform-tools/adb" ]]; then
            adb_bin="${ANDROID_SDK_ROOT}/platform-tools/adb"
        elif [[ -n "${ANDROID_HOME:-}" && -x "${ANDROID_HOME}/platform-tools/adb" ]]; then
            adb_bin="${ANDROID_HOME}/platform-tools/adb"
        elif [[ -n "${HOME:-}" && -x "${HOME}/Library/Android/sdk/platform-tools/adb" ]]; then
            adb_bin="${HOME}/Library/Android/sdk/platform-tools/adb"
        elif command -v adb >/dev/null 2>&1; then
            adb_bin="$(command -v adb)"
        fi
    fi

    [[ -x "$adb_bin" ]] || fail 20 "PM-MAGISK-ADB-001" \
        "adb could not be found." \
        "1. Android Studio > SDK Manager: install Android SDK Platform-Tools.\n2. Restart the emulator and try again."

    if [[ -z "$sdk_root" && -n "$emulator_bin" ]]; then
        sdk_root="$(cd "$(dirname "$emulator_bin")/.." && pwd -P)"
    fi
    if [[ -z "$sdk_root" && -n "${ANDROID_SDK_ROOT:-}" ]]; then
        sdk_root="$ANDROID_SDK_ROOT"
    fi
    if [[ -z "$sdk_root" && -n "${ANDROID_HOME:-}" ]]; then
        sdk_root="$ANDROID_HOME"
    fi
    if [[ -z "$sdk_root" && "$adb_bin" == */platform-tools/adb ]]; then
        sdk_root="$(cd "$(dirname "$adb_bin")/.." && pwd -P)"
    fi

    if [[ -z "$emulator_bin" && -n "$sdk_root" && -x "$sdk_root/emulator/emulator" ]]; then
        emulator_bin="$sdk_root/emulator/emulator"
    fi
    if [[ -z "$emulator_bin" && -n "${HOME:-}" && -x "${HOME}/Library/Android/sdk/emulator/emulator" ]]; then
        emulator_bin="${HOME}/Library/Android/sdk/emulator/emulator"
    fi

    [[ -x "$emulator_bin" ]] || fail 20 "PM-MAGISK-EMULATOR-001" \
        "The Android Emulator executable could not be found." \
        "1. Android Studio > SDK Manager: install Android Emulator.\n2. Start the AVD from Android Studio, then try again."
    [[ -d "$sdk_root" ]] || fail 20 "PM-MAGISK-SDK-001" \
        "The Android SDK root could not be resolved." \
        "1. Start the emulator from Android Studio.\n2. Or set ANDROID_SDK_ROOT to the SDK that owns this AVD."
}

resolve_state_directory() {
    phase="state_directory"
    if [[ -z "$state_dir" ]]; then
        state_dir="${TMPDIR:-/tmp}/com.proxymaxx.android-emulator-magisk"
    fi
    mkdir -p -m 700 "$state_dir"
    chmod 700 "$state_dir"
    log_file="$state_dir/magisk-$support_id.log"
    touch "$log_file"
    chmod 600 "$log_file"

    # Keep the output visible in the app's log while retaining an on-disk record.
    exec > >(tee -a "$log_file") 2>&1
}

adb_shell_text() {
    # -n keeps diagnostic adb calls from consuming the consent prompt's stdin.
    "$adb_bin" -s "$serial" shell -n "$@" 2>/dev/null | tr -d '\r'
}

working_su() {
    local output=""
    output="$(adb_shell_text 'PATH=$PATH:/debug_ramdisk su -c "id -u"' 2>/dev/null | awk 'NF { value=$0 } END { print value }' || true)"
    [[ "$output" == "0" ]] && return 0
    output="$(adb_shell_text 'su -c "id -u"' 2>/dev/null | awk 'NF { value=$0 } END { print value }' || true)"
    [[ "$output" == "0" ]]
}

# The host-side patch cache outlives a stock boot, so its presence cannot prove that today's
# root is ours. This marker lives in Magisk's volatile ramdisk and vanishes on the stock
# restart, so an unrelated rooted AVD is never reverted just because an old cache exists.
create_session_marker() {
    local output
    output="$(adb_shell_text \
        "PATH=\$PATH:/debug_ramdisk su -c \"umask 077; : > $SESSION_MARKER; echo marked\"" \
        2>/dev/null | awk 'NF { value=$0 } END { print value }' || true)"
    [[ "$output" == "marked" ]]
}

has_session_marker() {
    local output
    output="$(adb_shell_text \
        "PATH=\$PATH:/debug_ramdisk su -c \"test -f $SESSION_MARKER && echo marked\"" \
        2>/dev/null | awk 'NF { value=$0 } END { print value }' || true)"
    [[ "$output" == "marked" ]]
}

classify_platform() {
    local manufacturer="$1"
    local brand="$2"
    local hardware="$3"
    local combined
    combined="$(printf '%s %s %s' "$manufacturer" "$brand" "$hardware" | tr '[:upper:]' '[:lower:]')"

    if [[ -n "$avd_name" ]]; then
        platform="android_studio_avd"
    elif [[ "$combined" == *"genymotion"* ]]; then
        platform="genymotion"
    elif [[ "$combined" == *"bluestacks"* || "$combined" == *"bst"* ]]; then
        platform="bluestacks"
    elif [[ "$combined" == *"nox"* ]]; then
        platform="nox"
    elif [[ "$combined" == *"mumu"* || "$combined" == *"netease"* ]]; then
        platform="mumu"
    elif [[ "$combined" == *"ldplayer"* || "$combined" == *"ldmnq"* ]]; then
        platform="ldplayer"
    else
        platform="unknown_emulator"
    fi
}

resolve_avd_directory() {
    phase="avd_resolution"

    if [[ -z "$avd_home" ]]; then
        if [[ -n "${ANDROID_AVD_HOME:-}" ]]; then
            avd_home="$ANDROID_AVD_HOME"
        elif [[ -n "${ANDROID_USER_HOME:-}" ]]; then
            avd_home="${ANDROID_USER_HOME}/avd"
        elif [[ -n "${ANDROID_SDK_HOME:-}" ]]; then
            avd_home="${ANDROID_SDK_HOME}/.android/avd"
        elif [[ -n "${HOME:-}" ]]; then
            avd_home="${HOME}/.android/avd"
        else
            fail 20 "PM-MAGISK-AVD-001" \
                "The Android AVD home directory could not be resolved." \
                "1. Pass --avd-home, or set ANDROID_AVD_HOME.\n2. Restart the AVD from Android Studio and try again."
        fi
    fi

    local avd_ini="$avd_home/$avd_name.ini"
    if [[ -f "$avd_ini" ]]; then
        avd_dir="$(property_value "$avd_ini" "path")"
        if [[ -z "$avd_dir" ]]; then
            local relative_path
            relative_path="$(property_value "$avd_ini" "path.rel")"
            if [[ -n "$relative_path" ]]; then
                avd_dir="$(cd "$avd_home/.." && pwd -P)/$relative_path"
            fi
        fi
    fi
    if [[ -z "$avd_dir" ]]; then
        avd_dir="$avd_home/$avd_name.avd"
    fi

    config_file="$avd_dir/config.ini"
    [[ -f "$config_file" ]] || fail 20 "PM-MAGISK-AVD-002" \
        "The configuration for '$avd_name' was not found." \
        "1. In Android Studio's Device Manager use Show on Disk to locate the AVD.\n2. Verify ANDROID_AVD_HOME points at the directory holding it."

    local image_sysdir
    image_sysdir="$(property_value "$config_file" "image.sysdir.1")"
    [[ -n "$image_sysdir" ]] || fail 20 "PM-MAGISK-IMAGE-001" \
        "The AVD declares no system-image directory." \
        "1. Verify the AVD's system image in Device Manager.\n2. Recreate the AVD if its configuration is incomplete."

    if [[ "$image_sysdir" == /* ]]; then
        image_dir="${image_sysdir%/}"
    else
        image_dir="$sdk_root/${image_sysdir%/}"
    fi

    [[ -d "$image_dir" ]] || fail 20 "PM-MAGISK-IMAGE-002" \
        "The system-image directory does not exist: $image_dir" \
        "1. In SDK Manager, reinstall this system image.\n2. Recreate the AVD once the download finishes."

    if [[ -f "$image_dir/source.properties" ]]; then
        package_revision="$(property_value "$image_dir/source.properties" "Pkg.Revision")"
        local tags
        tags="$(property_value "$image_dir/source.properties" "SystemImage.TagId")"
        [[ "$tags" == *"google_apis_playstore"* ]] && play_store_config="true"
    fi
    case "$(property_value "$config_file" "PlayStore.enabled")" in
        true|yes|1) play_store_config="true" ;;
    esac
    # A false PlayStore.enabled must not become this function's status: the signed image tag
    # above is equally authoritative on modern AVDs.
    return 0
}

discover_device() {
    phase="device_discovery"
    [[ -n "$serial" ]] || fail 2 "PM-MAGISK-ARGS-001" \
        "A target emulator serial is required." \
        "1. Start one Android emulator.\n2. Run the setup again from the Android Emulator guide."

    local device_state
    device_state="$("$adb_bin" -s "$serial" get-state 2>&1 || true)"
    [[ "$device_state" == "device" ]] || fail 20 "PM-MAGISK-DEVICE-001" \
        "The target '$serial' is not ready (state: $device_state)." \
        "1. Wait for the emulator's home screen.\n2. Restart the emulator if adb reports it as offline."

    api_level="$(adb_shell_text getprop ro.build.version.sdk | head -n 1)"
    abi="$(adb_shell_text getprop ro.product.cpu.abi | head -n 1)"
    page_size="$(adb_shell_text getconf PAGESIZE | head -n 1 || true)"
    [[ -n "$page_size" ]] || page_size="unknown"

    avd_name="$("$adb_bin" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | awk 'NF && $0 != "OK" { print; exit }' || true)"

    local manufacturer brand hardware
    manufacturer="$(adb_shell_text getprop ro.product.manufacturer | head -n 1)"
    brand="$(adb_shell_text getprop ro.product.brand | head -n 1)"
    hardware="$(adb_shell_text getprop ro.hardware | head -n 1)"
    classify_platform "$manufacturer" "$brand" "$hardware"

    if adb_shell_text pm path com.android.vending | grep -q '^package:'; then
        play_store_package="true"
    fi

    console_port="${serial#emulator-}"

    [[ "$api_level" =~ ^[0-9]+$ ]] || fail 20 "PM-MAGISK-API-001" \
        "The Android API level could not be determined." \
        "1. Wait for Android to finish booting.\n2. Restart the emulator and try again."

    case "$abi" in
        arm64-v8a|armeabi-v7a|x86|x86_64) ;;
        *)
            fail 21 "PM-MAGISK-ABI-001" \
                "The emulator ABI '$abi' is not in the bundled Magisk APK." \
                "1. Use an ARM64 or x86_64 Android Studio AVD."
            ;;
    esac

    if [[ "$platform" == "android_studio_avd" ]]; then
        resolve_avd_directory
    fi
}

print_diagnostics() {
    echo "Target serial        : $serial"
    echo "Platform             : $platform"
    echo "AVD name             : ${avd_name:-unknown}"
    echo "Android API          : $api_level"
    echo "ABI                  : $abi"
    echo "Page size            : $page_size"
    echo "Play Store package   : $play_store_package"
    echo "Play Store AVD config: $play_store_config"
    echo "SDK root             : $sdk_root"
    echo "AVD directory        : ${avd_dir:-unavailable}"
    echo "System image         : ${image_dir:-unavailable}"
    echo "Package revision     : $package_revision"
    echo "Working su           : $(working_su && echo yes || echo no)"
}

platform_guidance() {
    case "$platform" in
        genymotion)
            printf '%s' "1. Open Genymotion's Advanced Developer Tools and enable Root Access.\n2. Reboot the device and run the setup again."
            ;;
        bluestacks|nox|mumu|ldplayer)
            printf '%s' "1. Enable root in that emulator's own settings.\n2. Restart the device and run the setup again."
            ;;
        *)
            printf '%s' "1. Create an AVD from a system image labelled “Google APIs”, which allows adb root.\n2. Or keep Magisk support enabled for a Play Store AVD."
            ;;
    esac
}

validate_platform_for_root() {
    phase="platform_validation"
    case "$platform" in
        android_studio_avd) ;;
        *)
            fail 21 "PM-MAGISK-PLATFORM-001" \
                "This emulator is not managed by Android Studio ($platform)." \
                "$(platform_guidance)"
            ;;
    esac
    [[ -n "$avd_name" ]] || fail 21 "PM-MAGISK-PLATFORM-002" \
        "The running emulator did not report an AVD name." \
        "1. Start the AVD from Android Studio's Device Manager.\n2. Try again."
}

resolve_source_image() {
    phase="image_resolution"
    if [[ -f "$image_dir/ramdisk.img" ]]; then
        source_image="$image_dir/ramdisk.img"
    elif [[ -f "$image_dir/init_boot.img" ]]; then
        fail 21 "PM-MAGISK-IMAGE-004" \
            "This AVD exposes init_boot.img, which the Android Emulator offers no safe per-session override for." \
            "1. Use an image that provides ramdisk.img.\n2. Cold Boot the AVD from Device Manager."
    else
        fail 21 "PM-MAGISK-IMAGE-003" \
            "No supported ramdisk.img was found in the system image." \
            "1. Reinstall the Play Store system image from SDK Manager.\n2. Run Diagnose and review the log."
    fi
    [[ -r "$source_image" ]] || fail 21 "PM-MAGISK-IMAGE-005" \
        "The source ramdisk is not readable." \
        "1. Check permissions on the SDK system-image directory.\n2. Reinstall the system image if it is damaged."
}

validate_magisk_resources() {
    phase="magisk_validation"
    [[ -f "$magisk_apk" ]] || fail 30 "PM-MAGISK-RESOURCE-001" \
        "The bundled Magisk APK is missing." \
        "1. Reinstall ProxyMaxx.\n2. Run Scripts/bundle-app.sh if building from source."
    [[ -f "$host_patch_script" ]] || fail 30 "PM-MAGISK-RESOURCE-002" \
        "The bundled Magisk host patch is missing." \
        "1. Reinstall ProxyMaxx.\n2. Run Scripts/bundle-app.sh if building from source."

    local resource_directory
    resource_directory="$(cd "$(dirname "$host_patch_script")" && pwd -P)"
    bootstrap_rc="$resource_directory/proxymaxx_magisk_bootstrap.rc"
    bootstrap_script="$resource_directory/proxymaxx_magisk_bootstrap.sh"
    bootstrap_injector="$resource_directory/proxymaxx_magisk_inject_bootstrap.sh"
    [[ -f "$bootstrap_rc" && -f "$bootstrap_script" && -f "$bootstrap_injector" ]] || \
        fail 30 "PM-MAGISK-RESOURCE-006" \
            "The bundled ProxyMaxx boot-time authorization helpers are missing." \
            "1. Reinstall ProxyMaxx.\n2. Run Scripts/bundle-app.sh if building from source."

    # Integrity is checked before anything is pushed to the device, so a tampered APK can
    # never be executed just by pointing the app at a bad resources directory.
    [[ "$(sha256_file "$magisk_apk")" == "$MAGISK_APK_SHA256" ]] || fail 30 "PM-MAGISK-RESOURCE-003" \
        "The bundled Magisk APK failed integrity verification." \
        "1. Reinstall ProxyMaxx from a trusted source.\n2. Do not continue with this APK."
    [[ "$(sha256_file "$host_patch_script")" == "$MAGISK_HOST_PATCH_SHA256" ]] || fail 30 "PM-MAGISK-RESOURCE-004" \
        "The bundled Magisk host patch failed integrity verification." \
        "1. Reinstall ProxyMaxx from a trusted source.\n2. Do not continue with this script."
    [[ "$(sha256_file "$bootstrap_rc")" == "$BOOTSTRAP_RC_SHA256" && \
       "$(sha256_file "$bootstrap_script")" == "$BOOTSTRAP_SCRIPT_SHA256" && \
       "$(sha256_file "$bootstrap_injector")" == "$BOOTSTRAP_INJECTOR_SHA256" ]] || \
        fail 30 "PM-MAGISK-RESOURCE-007" \
            "The bundled ProxyMaxx authorization helpers failed integrity verification." \
            "1. Reinstall ProxyMaxx from a trusted source.\n2. Do not continue with these files."

    local busybox_entry
    busybox_entry="$(/usr/bin/unzip -Z1 "$magisk_apk" | awk -v expected="lib/$abi/libbusybox.so" '$0 == expected { print; found=1 } END { exit found ? 0 : 1 }')" || \
        fail 30 "PM-MAGISK-RESOURCE-005" \
            "Magisk $MAGISK_VERSION carries no BusyBox for ABI '$abi'." \
            "1. Use an ARM64 or x86_64 AVD."
    [[ -n "$busybox_entry" ]]
}

has_valid_ramdisk_cache() {
    local source_hash safe_avd cache_directory cache_image metadata_file
    local cached_avd_name cached_source_hash cached_patched_hash cached_version actual_patched_hash
    source_hash="$(sha256_file "$source_image")"
    safe_avd="$(sanitize_component "$avd_name")"
    cache_directory="$state_dir/$safe_avd/$source_hash"
    cache_image="$cache_directory/ramdisk-magisk-$MAGISK_VERSION.img"
    metadata_file="$cache_directory/metadata"

    [[ -s "$cache_image" && -f "$metadata_file" ]] || return 1
    cached_avd_name="$(sed -n 's/^avd_name=//p' "$metadata_file" | head -n 1)"
    cached_source_hash="$(sed -n 's/^source_sha256=//p' "$metadata_file" | head -n 1)"
    cached_patched_hash="$(sed -n 's/^patched_sha256=//p' "$metadata_file" | head -n 1)"
    cached_version="$(sed -n 's/^magisk_version=//p' "$metadata_file" | head -n 1)"
    actual_patched_hash="$(sha256_file "$cache_image")"
    [[ "$cached_avd_name" == "$avd_name" && \
       "$cached_source_hash" == "$source_hash" && \
       "$cached_patched_hash" == "$actual_patched_hash" && \
       "$cached_version" == "$MAGISK_VERSION" ]]
}

request_consent() {
    phase="consent"
    echo ""
    echo "⚠️  Explicit consent required"
    echo ""
    echo "ProxyMaxx detected '$avd_name' (Android API $api_level, $abi, $page_size-byte pages)."
    echo "Installing the ProxyMaxx CA as a system certificate requires temporary root."
    echo ""
    echo "ProxyMaxx will:"
    echo "  • Use bundled Magisk $MAGISK_VERSION (GPLv3)"
    echo "  • Patch a temporary copy of this AVD's ramdisk"
    echo "  • Stop and cold-start only '$avd_name'"
    echo "  • Authorize only Android's ADB Shell UID (2000), from a one-shot boot service"
    echo "  • Keep a root-only recovery record until Revert puts the previous Shell policy back"
    echo "  • Leave the installed Android SDK image and the AVD configuration unchanged"
    echo "  • Disable Quick Boot load and save for this rooted session"
    echo ""
    echo "Root may affect Play Integrity, CTS and Google apps. Do not sign in with personal"
    echo "accounts in a rooted emulator. No Magisk screen or Superuser prompt will appear."
    echo "Answering yes authorizes the temporary boot service to grant adb-shell root only."
    echo ""

    local answer=""
    if ! IFS= read -r -p "Continue? [y/N] " answer; then
        answer=""
    fi
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
        y|yes) ;;
        *)
            echo ""
            echo "Setup cancelled. Nothing was changed."
            write_result "cancelled" "PM-MAGISK-CONSENT-001" "The user declined Magisk setup."
            exit 10
            ;;
    esac
}

append_patch_details_to_log() {
    local details_file="$1"
    [[ -s "$details_file" ]] || return 0

    # MagiskBoot output is useful for a failure report but would drown the normal flow.
    {
        printf '\n--- Magisk patch details ---\n'
        cat "$details_file"
        printf '%s\n' '--- end Magisk patch details ---'
    } >> "$log_file"
}

patch_ramdisk() {
    phase="patch"
    local source_hash safe_avd avd_state
    echo "Preparing a temporary Magisk ramdisk for Android API ${api_level}…"
    source_hash="$(sha256_file "$source_image")"
    safe_avd="$(sanitize_component "$avd_name")"
    avd_state="$state_dir/$safe_avd/$source_hash"
    mkdir -p -m 700 "$avd_state"
    patched_image="$avd_state/ramdisk-magisk-$MAGISK_VERSION.img"

    local metadata_file="$avd_state/metadata"
    if [[ -s "$patched_image" && -f "$metadata_file" ]]; then
        local cached_source_hash cached_patched_hash cached_version
        local cached_rc_hash cached_script_hash cached_injector_hash actual_patched_hash
        cached_source_hash="$(sed -n 's/^source_sha256=//p' "$metadata_file" | head -n 1)"
        cached_patched_hash="$(sed -n 's/^patched_sha256=//p' "$metadata_file" | head -n 1)"
        cached_version="$(sed -n 's/^magisk_version=//p' "$metadata_file" | head -n 1)"
        cached_rc_hash="$(sed -n 's/^bootstrap_rc_sha256=//p' "$metadata_file" | head -n 1)"
        cached_script_hash="$(sed -n 's/^bootstrap_script_sha256=//p' "$metadata_file" | head -n 1)"
        cached_injector_hash="$(sed -n 's/^bootstrap_injector_sha256=//p' "$metadata_file" | head -n 1)"
        actual_patched_hash="$(sha256_file "$patched_image")"
        if [[ "$cached_source_hash" == "$source_hash" && \
              "$cached_patched_hash" == "$actual_patched_hash" && \
              "$cached_version" == "$MAGISK_VERSION" && \
              "$cached_rc_hash" == "$BOOTSTRAP_RC_SHA256" && \
              "$cached_script_hash" == "$BOOTSTRAP_SCRIPT_SHA256" && \
              "$cached_injector_hash" == "$BOOTSTRAP_INJECTOR_SHA256" ]]; then
            echo "✅ Temporary Magisk ramdisk ready (cached)"
            return 0
        fi
        rm -f "$patched_image" "$metadata_file"
    fi

    work_dir="$(mktemp -d "$state_dir/.patch.XXXXXX")"
    local busybox="$work_dir/busybox"
    local candidate="$work_dir/ramdisk-magisk.img"
    local patch_details="$work_dir/patch-details.log"
    : > "$patch_details"
    chmod 600 "$patch_details"

    # Magisk's own bundled BusyBox is what host_patch.sh drives the patch with.
    if ! /usr/bin/unzip -p "$magisk_apk" "lib/$abi/libbusybox.so" \
        > "$busybox" 2>> "$patch_details"; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-RESOURCE-008" \
            "The bundled Magisk patch utility could not be prepared." \
            "1. Reinstall ProxyMaxx.\n2. Review the diagnostic log."
    fi
    chmod 700 "$busybox"

    remote_work_created="true"
    if ! {
        "$adb_bin" -s "$serial" push "$busybox" /data/local/tmp/busybox &&
        "$adb_bin" -s "$serial" push "$magisk_apk" /data/local/tmp/magisk.apk &&
        "$adb_bin" -s "$serial" push "$host_patch_script" /data/local/tmp/proxymaxx_host_patch.sh &&
        "$adb_bin" -s "$serial" push "$bootstrap_rc" /data/local/tmp/proxymaxx_magisk_bootstrap.rc &&
        "$adb_bin" -s "$serial" push "$bootstrap_script" /data/local/tmp/proxymaxx_magisk_bootstrap.sh &&
        "$adb_bin" -s "$serial" push "$bootstrap_injector" /data/local/tmp/proxymaxx_magisk_inject_bootstrap.sh &&
        "$adb_bin" -s "$serial" push "$source_image" /data/local/tmp/proxymaxx_ramdisk.img
    } >> "$patch_details" 2>&1; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-006" \
            "The files needed to prepare temporary root could not be copied to the emulator." \
            "1. Restart adb and cold-boot the emulator.\n2. Try again."
    fi

    # 1. Magisk patches the ramdisk (unmodified upstream script).
    if ! "$adb_bin" -s "$serial" shell -n sh \
        /data/local/tmp/proxymaxx_host_patch.sh /data/local/tmp/proxymaxx_ramdisk.img \
        >> "$patch_details" 2>&1; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-001" \
            "Magisk could not patch the API $api_level ramdisk." \
            "1. Cold Boot the stock emulator and retry.\n2. Reinstall the Android API $api_level Play Store image."
    fi

    # 2. Our glue adds the one-shot adb-shell authorization service to that ramdisk.
    if ! "$adb_bin" -s "$serial" shell -n sh \
        /data/local/tmp/proxymaxx_magisk_inject_bootstrap.sh \
        /data/local/tmp/proxymaxx_ramdisk.img.magisk \
        /data/local/tmp/proxymaxx_magisk_bootstrap.rc \
        /data/local/tmp/proxymaxx_magisk_bootstrap.sh \
        >> "$patch_details" 2>&1; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-005" \
            "The boot-time ADB Shell authorization service could not be added to the ramdisk." \
            "1. Cold Boot the stock emulator and retry.\n2. Review the diagnostic log."
    fi

    if ! "$adb_bin" -s "$serial" pull \
        /data/local/tmp/proxymaxx_ramdisk.img.magisk "$candidate" \
        >> "$patch_details" 2>&1; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-002" \
            "The patched ramdisk could not be copied back from the emulator." \
            "1. Check available disk space.\n2. Restart adb and retry."
    fi

    phase="patch_validation"
    if [[ ! -s "$candidate" ]]; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-003" \
            "Magisk produced an empty patched ramdisk." \
            "1. Reinstall the Android system image.\n2. Review the diagnostic log."
    fi

    local patched_hash
    patched_hash="$(sha256_file "$candidate")"
    if [[ "$patched_hash" == "$source_hash" ]]; then
        append_patch_details_to_log "$patch_details"
        fail 30 "PM-MAGISK-PATCH-004" \
            "The patched ramdisk is identical to the stock one, so nothing was patched." \
            "1. Retry with a cold-booted AVD.\n2. Review the diagnostic log."
    fi

    mv "$candidate" "$patched_image"
    chmod 600 "$patched_image"
    {
        printf 'avd_name=%s\n' "$avd_name"
        printf 'api_level=%s\n' "$api_level"
        printf 'abi=%s\n' "$abi"
        printf 'page_size=%s\n' "$page_size"
        printf 'package_revision=%s\n' "$package_revision"
        printf 'source_image=%s\n' "$source_image"
        printf 'source_sha256=%s\n' "$source_hash"
        printf 'patched_sha256=%s\n' "$patched_hash"
        printf 'magisk_version=%s\n' "$MAGISK_VERSION"
        printf 'bootstrap_rc_sha256=%s\n' "$BOOTSTRAP_RC_SHA256"
        printf 'bootstrap_script_sha256=%s\n' "$BOOTSTRAP_SCRIPT_SHA256"
        printf 'bootstrap_injector_sha256=%s\n' "$BOOTSTRAP_INJECTOR_SHA256"
    } > "$metadata_file"
    chmod 600 "$metadata_file"
    append_patch_details_to_log "$patch_details"
    echo "✅ Temporary Magisk ramdisk ready"
}

wait_for_device_absent() {
    local attempts=0
    while (( attempts < 60 )); do
        if ! "$adb_bin" -s "$serial" get-state >/dev/null 2>&1; then
            return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    return 1
}

wait_for_boot() {
    local attempts=0
    while (( attempts < 300 )); do
        if [[ -n "$emulator_pid" ]] && ! kill -0 "$emulator_pid" >/dev/null 2>&1; then
            return 1
        fi
        if "$adb_bin" -s "$serial" get-state >/dev/null 2>&1; then
            local completed
            completed="$(adb_shell_text getprop sys.boot_completed | head -n 1 || true)"
            if [[ "$completed" == "1" ]]; then
                return 0
            fi
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    return 1
}

authorize_adb_shell_root() {
    phase="magisk_shell_authorization"
    local attempts=0
    while (( attempts < 90 )); do
        if "$adb_bin" -s "$serial" shell -n test -f "$POLICY_READY_MARKER" \
            >/dev/null 2>&1; then
            working_su && return 0
        fi
        sleep 1
        attempts=$((attempts + 1))
    done

    local bootstrap_output
    bootstrap_output="$(adb_shell_text cat "$BOOTSTRAP_LOG" 2>/dev/null || true)"
    [[ -n "$bootstrap_output" ]] && echo "Boot authorization log: $bootstrap_output"
    fail 50 "PM-MAGISK-ROOT-002" \
        "The one-shot boot service did not authorize Android's ADB Shell UID." \
        "1. Cold-boot the stock AVD and retry.\n2. Review the diagnostic log."
}

restore_adb_shell_policy() {
    if ! working_su; then
        echo "⚠️  Magisk root is not reachable, so the previous ADB Shell policy cannot be restored."
        return 1
    fi

    local output
    output="$(adb_shell_text \
        "PATH=\$PATH:/debug_ramdisk su -c '$BOOTSTRAP_RUNTIME restore && echo restored'" \
        2>/dev/null | awk 'NF { value=$0 } END { print value }' || true)"
    if [[ "$output" != "restored" ]]; then
        echo "⚠️  The previous Magisk policy for ADB Shell could not be restored."
        local bootstrap_output
        bootstrap_output="$(adb_shell_text cat "$BOOTSTRAP_LOG" 2>/dev/null || true)"
        [[ -n "$bootstrap_output" ]] && echo "Policy restore log: $bootstrap_output"
        return 1
    fi
    policy_restore_succeeded="true"
    echo "✅ Previous Magisk ADB Shell policy restored"
}

launch_stock_emulator() {
    local stock_log="$state_dir/stock-$support_id.log"
    ANDROID_AVD_HOME="$avd_home" nohup "$emulator_bin" \
        -avd "$avd_name" \
        -port "$console_port" \
        -no-snapshot-load > "$stock_log" 2>&1 < /dev/null &
    local stock_pid="$!"
    # The app starts this script in its own process; removing the emulator from the job table
    # stops the shell from taking Android down with it when the script exits.
    disown "$stock_pid" >/dev/null 2>&1 || true
}

rollback_to_stock() {
    rollback_attempted="true"
    phase="rollback"
    echo ""
    echo "↩️  Restoring the stock emulator…"

    # Restore while Magisk is still active; the durable backup stays available for a later
    # retry if this fails or the emulator was cold-booted first.
    local policy_restore_failed="false"
    restore_adb_shell_policy || policy_restore_failed="true"
    "$adb_bin" -s "$serial" emu kill >/dev/null 2>&1 || true
    if [[ -n "$emulator_pid" ]]; then
        kill "$emulator_pid" >/dev/null 2>&1 || true
    fi
    wait_for_device_absent || true
    launch_stock_emulator

    local attempts=0
    while (( attempts < 300 )); do
        if "$adb_bin" -s "$serial" get-state >/dev/null 2>&1; then
            local completed
            completed="$(adb_shell_text getprop sys.boot_completed | head -n 1 || true)"
            if [[ "$completed" == "1" ]]; then
                if working_su; then
                    echo "⚠️  Android restarted but Magisk root is still active."
                    return 1
                fi
                rollback_succeeded="true"
                echo "✅ Stock emulator restarted; Magisk root is inactive"
                if [[ "$policy_restore_failed" == "true" ]]; then
                    return 2
                fi
                return 0
            fi
        fi
        sleep 1
        attempts=$((attempts + 1))
    done
    echo "⚠️  The automatic stock restart did not complete. Use Device Manager → Cold Boot."
    return 1
}

clear_proxy_after_stock_restore() {
    phase="restore_proxy_cleanup"

    # Android may not flush a settings change made immediately before the rooted emulator is
    # stopped, so the cleanup is applied again once the stock boot is up.
    if ! "$adb_bin" -s "$serial" shell -n settings put global http_proxy :0 >/dev/null 2>&1; then
        return 1
    fi

    local proxy_value
    proxy_value="$(adb_shell_text settings get global http_proxy | head -n 1 || true)"
    [[ "$proxy_value" == ":0" || "$proxy_value" == "null" ]]
}

launch_rooted_emulator() {
    phase="emulator_stop"
    echo "Stopping '$avd_name'…"
    if ! "$adb_bin" -s "$serial" emu kill >/dev/null 2>&1; then
        fail 40 "PM-MAGISK-STOP-001" \
            "The emulator did not accept the stop command." \
            "1. Close the emulator from Device Manager.\n2. Start it again and retry."
    fi
    wait_for_device_absent || fail 40 "PM-MAGISK-STOP-002" \
        "The emulator did not stop within 60 seconds." \
        "1. Force-stop the AVD from Device Manager.\n2. Cold Boot it and retry."

    phase="rooted_boot"
    local launch_log="$state_dir/rooted-$support_id.log"
    echo "Cold-starting '$avd_name' with temporary Magisk root…"
    ANDROID_AVD_HOME="$avd_home" nohup "$emulator_bin" \
        -avd "$avd_name" \
        -port "$console_port" \
        -ramdisk "$patched_image" \
        -no-snapshot-load \
        -no-snapshot-save > "$launch_log" 2>&1 < /dev/null &
    emulator_pid="$!"
    disown "$emulator_pid" >/dev/null 2>&1 || true
    rooted_launch_started="true"

    wait_for_boot || fail 40 "PM-MAGISK-BOOT-001" \
        "The Magisk-rooted emulator did not finish booting within five minutes." \
        "1. Review $launch_log.\n2. Reinstall the Android API $api_level system image."

    local booted_api booted_avd
    booted_api="$(adb_shell_text getprop ro.build.version.sdk | head -n 1)"
    booted_avd="$("$adb_bin" -s "$serial" emu avd name 2>/dev/null | tr -d '\r' | awk 'NF && $0 != "OK" { print; exit }' || true)"
    [[ "$booted_api" == "$api_level" && "$booted_avd" == "$avd_name" ]] || fail 40 "PM-MAGISK-BOOT-002" \
        "A different emulator connected after the restart." \
        "1. Stop other AVDs and retry.\n2. Use Diagnose to confirm the target serial and AVD name."
}

verify_magisk_root() {
    phase="root_verification"
    echo ""
    echo "Waiting for the boot-time ADB Shell root policy…"

    # The root init service is awaited before the first su probe; probing earlier would ask
    # Magisk's own manager to authorize Shell interactively, which we never want.
    authorize_adb_shell_root
    if working_su; then
        create_session_marker || fail 50 "PM-MAGISK-SESSION-001" \
            "Root works, but ProxyMaxx could not record ownership of this temporary session." \
            "1. Cold-boot the stock AVD and retry.\n2. Review the diagnostic log."
        echo "✅ Magisk root verified"
        return 0
    fi

    fail 50 "PM-MAGISK-ROOT-001" \
        "Magisk started, but adb-shell root was not granted." \
        "1. Cold-boot the stock AVD and retry.\n2. Review the diagnostic log."
}

restore_mode() {
    phase="restore_consent"
    echo ""
    echo "⚠️  Restore consent required"
    echo ""
    echo "ProxyMaxx found an active temporary Magisk session for '$avd_name'."
    echo "Reverting will:"
    echo "  • Keep the proxy and tunnel cleanup already performed"
    echo "  • Stop only '$avd_name'"
    echo "  • Restart it with the stock Android Studio ramdisk"
    echo "  • Remove active Magisk root and the transient certificate mounts"
    echo "  • Put back the Magisk policy that existed before ProxyMaxx authorized ADB Shell"
    echo "  • Keep the AVD's apps, user data, SDK image and configuration"
    echo ""
    local answer=""
    if ! IFS= read -r -p "Continue? [y/N] " answer; then
        answer=""
    fi
    answer="$(printf '%s' "$answer" | tr '[:upper:]' '[:lower:]')"
    case "$answer" in
        y|yes) ;;
        *)
            echo "Restore cancelled."
            write_result "cancelled" "PM-MAGISK-RESTORE-CONSENT-001" "The user declined the restore."
            exit 10
            ;;
    esac

    rooted_launch_started="true"
    local rollback_status=0
    rollback_to_stock || rollback_status=$?
    if [[ "$rollback_status" == "1" ]]; then
        # Avoid a second rollback while reporting an explicit restore that failed.
        rooted_launch_started="false"
        fail 80 "PM-MAGISK-ROLLBACK-001" \
            "The stock emulator could not be restarted automatically." \
            "1. Open Device Manager.\n2. Choose Cold Boot Now for '$avd_name'."
    fi

    # The rooted session is gone; a failed cleanup below must not trigger another restart.
    rooted_launch_started="false"
    if ! clear_proxy_after_stock_restore; then
        fail 80 "PM-MAGISK-RESTORE-PROXY-001" \
            "The emulator is back on a stock boot, but its proxy setting could not be cleared." \
            "1. Set the emulator's Wi-Fi proxy to None.\n2. Retry the revert."
    fi
    if [[ "$rollback_status" == "2" ]]; then
        fail 80 "PM-MAGISK-RESTORE-POLICY-001" \
            "The emulator is back on a stock boot, but the previous Magisk ADB Shell policy could not be put back." \
            "1. Run the setup again, then immediately Revert to retry the saved recovery record."
    fi

    operation_complete="true"
    phase="complete"
    write_result "success" "" "The emulator restarted without the temporary Magisk ramdisk."
    echo "✅ '$avd_name' restarted without temporary Magisk root"
}

main() {
    case "$mode" in
        root|restore|restore-if-needed|diagnose) ;;
        *)
            echo "Invalid mode: $mode" >&2
            print_usage >&2
            exit 2
            ;;
    esac

    resolve_tools
    resolve_state_directory
    print_header
    discover_device
    print_diagnostics

    if [[ "$mode" == "diagnose" ]]; then
        phase="complete"
        operation_complete="true"
        write_result "success" "" "Diagnostics completed without changes."
        echo ""
        echo "✅ Diagnostics complete; nothing was changed"
        exit 0
    fi

    if [[ "$mode" == "restore-if-needed" ]]; then
        phase="restore_detection"
        # Three independent facts must agree before anything is touched: it is an Android
        # Studio AVD, root is live, and the volatile session marker says we created it.
        if [[ "$platform" != "android_studio_avd" ]] || \
           ! working_su || ! has_session_marker; then
            operation_complete="true"
            write_result "success" "" "No active ProxyMaxx Magisk session was detected."
            echo "ℹ️  No active ProxyMaxx Magisk session was detected; no boot changes were made"
            exit 0
        fi

        validate_platform_for_root
        resolve_source_image
        if ! has_valid_ramdisk_cache; then
            operation_complete="true"
            write_result "success" "" "Root is active, but it does not match a ProxyMaxx Magisk cache."
            echo "ℹ️  Root is active, but it was not identified as a ProxyMaxx Magisk session"
            echo "   This emulator was left unchanged."
            exit 0
        fi

        restore_mode
        exit 0
    fi

    validate_platform_for_root

    if [[ "$mode" == "restore" ]]; then
        restore_mode
        exit 0
    fi

    if working_su; then
        phase="complete"
        operation_complete="true"
        write_result "success" "" "The emulator already has working root."
        echo "✅ This emulator already has working root; no Magisk patch was needed"
        exit 0
    fi

    resolve_source_image
    validate_magisk_resources
    request_consent
    patch_ramdisk
    launch_rooted_emulator
    verify_magisk_root

    phase="complete"
    operation_complete="true"
    write_result "success" "" "Magisk root is ready for certificate installation."
    echo ""
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "✅ Magisk root is ready"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
    echo "AVD     : $avd_name"
    echo "API     : $api_level"
    echo "ABI     : $abi"
    echo "Magisk  : $MAGISK_VERSION"
    echo "Session : Temporary — a normal stock cold boot removes active root"
}

trap handle_signal INT TERM
trap cleanup EXIT

main
