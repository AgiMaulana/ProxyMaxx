#!/system/bin/sh

# Extends the ramdisk produced by Magisk's unmodified host_patch.sh with the
# ProxyMaxx-owned one-shot init service. Upstream Magisk artifacts stay untouched, so the
# extra behaviour is a separate, auditable addition rather than a patched Magisk.

set -eu

target_image="${1:-}"
bootstrap_rc="${2:-}"
bootstrap_script="${3:-}"
magiskboot="./magiskboot"

cleanup() {
    rm -f "${target_image}.proxymaxx.cpio" "${target_image}.proxymaxx"
}
trap cleanup EXIT INT TERM

[[ -n "$target_image" && -s "$target_image" ]] || exit 2
[[ -n "$bootstrap_rc" && -s "$bootstrap_rc" ]] || exit 2
[[ -n "$bootstrap_script" && -s "$bootstrap_script" ]] || exit 2

cd "$(dirname "$target_image")"
target_image="$(basename "$target_image")"
bootstrap_rc="$(basename "$bootstrap_rc")"
bootstrap_script="$(basename "$bootstrap_script")"
work_cpio="${target_image}.proxymaxx.cpio"
candidate_image="${target_image}.proxymaxx"

[[ -x "$magiskboot" ]] || exit 3
rm -f "$work_cpio" "$candidate_image"

"$magiskboot" decompress "$target_image" "$work_cpio"
"$magiskboot" cpio "$work_cpio" \
    "add 0644 overlay.d/proxymaxx_magisk_bootstrap.rc $bootstrap_rc" \
    "add 0750 overlay.d/sbin/proxymaxx_magisk_bootstrap.sh $bootstrap_script"
"$magiskboot" compress=gzip "$work_cpio" "$candidate_image"

[[ -s "$candidate_image" ]] || exit 4
mv -f "$candidate_image" "$target_image"
