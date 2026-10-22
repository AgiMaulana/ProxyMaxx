# Android

Two things are needed to capture an Android device or emulator:

1. **Reach the proxy.** Either the device's HTTP proxy setting, or the tunnel app, which
   carries every app's TCP traffic regardless of whether the app honours that setting.
2. **Trust the certificate.** Without it, HTTPS is carried but cannot be decrypted — every
   TLS handshake fails instead.

ProxyMaxx automates both from **Android → Install Certificate on Android…**.

## The emulator guide

**Android → Open Android Emulator Guide** (or the Android button in the toolbar) opens a window
that picks a connected device, shows the proxy address it will use, and runs the installer.

`Advanced Mode` chooses the route:

| Mode | What it does |
|---|---|
| **Automatic** | `adb root` on a Google APIs image; on a Google Play AVD it offers the bundled Magisk route instead. |
| **Google APIs (adb root)** | Only the `adb root` path. Nothing is patched; an unrootable AVD is reported rather than modified. |
| **Manual command** | Touches nothing. Shows the exact command to run yourself. |
| **Revert all changes** | Clears the proxy, removes the tunnel app, and returns a Magisk AVD to a stock boot. |

The proxy address is `10.0.2.2:<HTTP port>` for an emulator — that is how an AVD reaches its
host — and this Mac's LAN address for a real device. The SOCKS5 port is passed to the tunnel
app as well, since that is how the tunnel actually carries traffic.

### Google Play AVDs

Play Store images ship a production-signed `adbd`, so `adb root` does not exist there. The
bundled **Magisk** route patched a temporary copy of the AVD's ramdisk instead. It is opt-in,
it is announced before it runs, and it is undone by Revert.

The guide runs the installer as the logged-in user, not as an administrator: root is obtained
on the device, so this Mac is never asked for a password. The Magisk toggle is the consent, and
the installer's own consent question is answered from it, which is why its adb calls read from
`/dev/null` and only the two that pipe a heredoc to the device keep the caller's input.

- Only that one AVD is stopped and cold-started, with `-ramdisk <patched>`.
- Only Android's **ADB Shell UID (2000)** is granted root, by a one-shot boot service. No
  Magisk screen or Superuser prompt appears, and other apps are not authorized.
- The previous Shell policy is kept in a root-only Magisk record until Revert verifies that it
  has been put back.
- The installed SDK image and the AVD configuration are never modified, and Quick Boot is
  disabled for the rooted session.
- Root may affect Play Integrity, CTS and Google apps. Do not sign in with personal accounts in
  a rooted emulator.

An emulator built from a **Google APIs** image needs none of this. If you can choose, choose
that one.

## Physical devices

**Android → Open Android Device Guide** covers the manual steps: set the Wi-Fi proxy to this
Mac's LAN address and port, then install the exported CA. The installer puts the certificate in
the **system** trust store, so an app that ships its own network-security configuration trusts
it. An app that pins a specific certificate still refuses the intercepted leaf, and that kind of
pinning cannot be worked around by installing a CA.

The certificate install is a real change to a real device, and the user-store copy persists
across reboots until Revert removes it, so real devices are only processed when **Also process
attached physical devices** is ticked.

## The tunnel app

`Android/ProxyMaxxVpn` is a userspace TCP/IP-over-tun app that hands each intercepted TCP
connection to ProxyMaxx's SOCKS5 listener and leaves UDP alone except for port 443, which it
withholds so QUIC falls back to TCP and stays visible. It defaults to host `10.0.2.2`, SOCKS5
`8989`, HTTP `9090`.

Build it into the app bundle with:

```sh
Scripts/build-android-vpn.sh
```

That writes `Resources/android/proxymaxx-vpn.apk`, which the installer picks up and the
guide installs and launches with the proxy details attached. Without it, the certificate and
proxy steps still work and you install the tunnel yourself.

## Running it from the command line

For scripted or headless use, the same paths are reachable as flags:

```sh
.build/debug/ProxyMaxxApp --autostart --port 9090 --android-install --android-serial emulator-5554
.build/debug/ProxyMaxxApp --autostart --android-install --android-no-magisk
.build/debug/ProxyMaxxApp --autostart --android-revert
```

Output goes to stderr with an `[cli]` prefix, and the full installer log is written to
`~/Library/Application Support/ProxyMaxx/android/run.log`.

## Where things live

| Path | What |
|---|---|
| `Resources/android/*.sh` | The installers; see `Resources/android/README.md` |
| `Resources/android/Magisk/v30.7/` | Unmodified Magisk plus our glue, and `SOURCE.md` |
| `~/Library/Application Support/ProxyMaxx/android/` | Logs and the Magisk ramdisk cache |
| `Android/ProxyMaxxVpn/` | The tunnel app |
| `Scripts/build-android-vpn.sh` | Builds the tunnel into `Resources/android/` |

## Limits

- The Magisk route is only for Android Studio AVDs. It has been exercised on the Google APIs
  path and on a Google Play AVD (API 36, arm64-v8a), where the consent hand-off above is what
  makes it run.
- Selecting a device is per-device: proxy, certificate and tunnel are applied per serial.
- Reverting clears the proxy, deletes the certificate from the trust stores and removes the
  tunnel app. The user-store copy is a real file under `/data`, so it survives a reboot; Revert
  deletes it rather than waiting for one. The system-store copy is a tmpfs and a reboot clears
  it on its own. On the Magisk route Revert also performs that stock restart for you.
