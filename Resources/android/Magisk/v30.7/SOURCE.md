# Magisk v30.7

This directory contains **unmodified** Magisk v30.7 artifacts, distributed under the GNU
General Public License version 3 (`LICENSE`), together with separately named
ProxyMaxx-owned shell and init configuration files.

ProxyMaxx invokes Magisk only after explicit user consent, and only to prepare a temporary
ramdisk for an Android Studio AVD. It does not incorporate Magisk code into its own binaries.

Upstream project: https://github.com/topjohnwu/Magisk
Release: https://github.com/topjohnwu/Magisk/releases/tag/v30.7
Source tag: https://github.com/topjohnwu/Magisk/tree/v30.7
Source commit: `e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac`

The recursive snapshot includes these upstream submodule commits:

- `crt0`: `9dfa67b4d543f1b6bf2e936f560fbe77ca2a226a`
- `cxx-rs`: `b09b91554b392523f633b9e3cbe0b43273528c71`
- `libcxx`: `d5117df3ba7704aab06c3a30b97c7529c931662b`
- `lsplt`: `cef80a97a73184b4def9b3e1148884365fc173fd`
- `lz4`: `d44371841a2f1728a3f36839fd4b7e872d0927d3`
- `selinux`: `be1b39a657fee7faacfae548b75cb53302043a01`
- `system_properties`: `b7c2088565fbe13d22fe074960332e89615bb4aa`

## What each file is

- `Magisk-v30.7.apk` — the official release APK, unmodified.
- `host_patch.sh` — an exact copy of `scripts/host_patch.sh` from the v30.7 source tag,
  unmodified. This is what actually patches the ramdisk.
- `proxymaxx_magisk_bootstrap.rc`, `proxymaxx_magisk_bootstrap.sh`,
  `proxymaxx_magisk_inject_bootstrap.sh` — ProxyMaxx-owned glue. It adds a one-shot,
  Shell-UID-only authorization service to the temporary ramdisk; it does not modify the
  upstream APK or `host_patch.sh`. At runtime the bootstrap keeps the previous Shell policy in
  a root-only Magisk database record until Revert verifies that it has been put back.
- `MANIFEST.sha256` — integrity hashes. The installer verifies the APK, the host patch and the
  glue before use, and refuses to continue if any digest does not match.
- `LICENSE` — the complete GNU GPL version 3 license from the upstream tag.

## Written source offer

This document is ProxyMaxx's written offer to provide anyone who has received the bundled
Magisk v30.7 binary with the complete, machine-readable corresponding source described above,
including the recorded submodule commits. ProxyMaxx will provide either access to copy the
source from a network server at no charge, or a copy on a durable physical medium for no more
than the reasonable cost of physically providing it.

Equivalent, no-charge network access to that exact source is available upstream: clone
https://github.com/topjohnwu/Magisk, check out commit
`e8a58776f1d7bdf852072ad0baa6eceb9a1e4aac`, then initialise and update all submodules
recursively to obtain the commits listed above.

## Why this is here at all

Play Store AVDs ship a production-signed `adbd`, so `adb root` is unavailable and there is no
other way to mount over the system CA directory. Emulators built from a **Google APIs** image
do not need any of this — plain `adb root` is enough — and ProxyMaxx prefers that path when
it is available.
