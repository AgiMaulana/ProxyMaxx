# Android resources

Everything the macOS app needs to set an Android emulator (or device) up for capture. The app
reads these from `Contents/Resources/Android` inside the bundle; during `swift run` it falls
back to this directory. `PROXYMAXX_RESOURCES` overrides both.

## `install_certificate_android_emulator.sh`

The one that does the work. The app and anyone running it by hand use the same flags, so both
do the same thing.

```
-m, --mode <all|proxy|certificate|revertProxy>   required
-i, --ip <address>        how the device reaches this Mac (10.0.2.2 for an emulator)
-p, --port <port>         ProxyMaxx HTTP proxy port
-c, --cert <path>         root certificate, PEM
    --socks-port <port>   SOCKS5 port (default 8989)
    --vpn-apk <path>      tunnel APK to install and launch
    --serial <serial>     only this device
    --include-physical    also process real devices (off by default)
    --uninstall-vpn       on revert
    --enable-magisk + --magisk-script/-apk/-host-patch/-state-dir
    --restore-magisk      on revert
```

What it does, in order:

1. Resolves `adb`, preferring Android Studio's SDK. A Homebrew `adb` can restart the adb server
   mid-setup and make a healthy emulator vanish, so it is not preferred.
2. Establishes root: an existing `su`, then `adb root`, then, only if allowed and only on an
   Android Studio AVD, the Magisk route.
3. Installs the CA as a **system** CA, which is the store an app that ships its own
   network-security-config checks the intercepted leaf against. The system directory is a
   read-only image, so the platform's own certificates plus ours are placed on a tmpfs over
   `/system/etc/security/cacerts` and that tmpfs is bind-mounted with `nsenter` into every
   zygote and app mount namespace, so already-running and newly forked processes both see it.
   The certificate is **also** written to the user store (`/data/misc/user/0/cacerts-added`,
   or `/data/misc/keychain/cacerts-added` where that is the older location), as
   `system:system`, mode `644`, under the file name the platform looks for, because Chrome and
   some network stacks consult it.
4. Pins the CA's public key for Chrome, WebView and content-shell through their
   `*-command-line` files, then restarts the apps so they read the new certificate. The tunnel
   app is deliberately spared.
5. Sets `global http_proxy` to `--ip:--port`, and optionally installs and launches the tunnel.
   With the tunnel, the proxy is cleared instead: a leftover setting would put the proxy's own
   address on the tunnel path, where nothing can bootstrap it.

Revert is the same script with `-m revertProxy`: it clears the proxy, deletes the certificate
from the trust stores, removes the tunnel app, and restores a Magisk session if this app created
one. The user-store copy is a real file under `/data`, so a reboot would not undo it; the
system-store copy is a tmpfs that a reboot clears on its own.

Note `-m proxy` is the escape hatch: it sets the proxy with **no** certificate and **no** root.
HTTP is captured, HTTPS is not decrypted.

## `install_certificate_android_emulator_magisk.sh`

Only used when `adb root` is unavailable, in practice an Android Studio **Google Play** AVD,
where `adbd` is production-signed. It:

- resolves the running AVD from its serial, reading `config.ini` for `image.sysdir.1`;
- verifies the bundled Magisk APK, `host_patch.sh` and the ProxyMaxx glue by SHA-256;
- patches a **copy** of the AVD's `ramdisk.img` with unmodified Magisk `host_patch.sh`, then
  adds the ProxyMaxx one-shot boot service to it;
- cold-starts that AVD with `-ramdisk <patched>` and `-no-snapshot-load/-save`;
- waits for boot and for the boot service to authorize **only** ADB Shell's UID (2000).

The installed SDK image, the AVD configuration and Magisk's own manager app are never changed.
The patch cache lives under the app's Application Support directory and is validated against a
metadata record (source hash, patched hash, version, glue hashes) before it is reused.

`--mode restore-if-needed` does nothing unless the AVD is an Android Studio AVD, has working
root, **and** carries the volatile session marker in Magisk's ramdisk, three independent facts,
so an unrelated rooted emulator is never reverted just because an old cache exists.

Modes: `root`, `restore`, `restore-if-needed`, `diagnose`. Exit code `10` means the user
declined a consent prompt.

## `Magisk/v30.7/`

Unmodified upstream Magisk v30.7 (GPLv3, see `LICENSE`) plus ProxyMaxx-owned glue. Read
`SOURCE.md` before changing anything here: the APK and `host_patch.sh` are verified by the
published release digests, so both must stay byte-for-byte upstream. The glue files are ours
and their digests are pinned in the installer, so editing them means updating
`MANIFEST.sha256` **and** the three `BOOTSTRAP_*_SHA256` constants in the Magisk script.

## `proxymaxx-vpn.apk`

The Android tunnel, built by `Scripts/build-android-vpn.sh` from `Android/ProxyMaxxVpn` and
gitignored like the other staged artefacts, so a fresh clone has none. Not required for the
certificate and proxy steps; when it is missing the guide says how to build it.
