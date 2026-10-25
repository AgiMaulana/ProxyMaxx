# ProxyMaxx, the browser side

A Chromium and Firefox extension that makes a browser actually use the proxy, and then reports which of
the things that stop capture are still stopping it.

It exists for the same reason the Android app does, since the platform's own proxy setting is
advisory and something else can win, but the mechanism is the opposite. Android needed a
`VpnService` because the system proxy cannot see packets. A browser hands you no socket at
all, so there is nothing to intercept with. What it does hand you is control of its own proxy
setting, which is the one surface the macOS app cannot reach:

- A browser can be running its own proxy configuration, set by a policy, another extension or
  a command-line flag, which silently overrides the system setting the app wrote. The app
  cannot see this; the extension can.
- Chromium bypasses loopback implicitly, so `http://localhost` never reaches the proxy.
- Connections live across a proxy change, so a capture that "did not work" is often just a
  tab that never reconnected.
- Nothing can install an extension for the user, so the last step is a click.

## What it does

```
popup ──▶ service worker ──┬── chrome.proxy.settings ──▶ the browser's own proxy setting
                           ├── chrome.proxy.onProxyError ──▶ the failure, not the silence
                           └── connectNative ──▶ browser host ──▶ browser-bridge.json
                                                                  (written by the app or the CLI)
```

- **Force the proxy.** `fixed_servers` at `127.0.0.1:<port>`, saved and restored by clearing
  the extension's own level rather than replaying a snapshot.
- **Report the owner.** `chrome.proxy.settings.get()` returns the effective mode and its
  `levelOfControl`, which distinguishes "this extension", "another extension", "a policy or
  the command line", and "free".
- **Report the failure.** `chrome.proxy.onProxyError` surfaces
  `net::ERR_PROXY_CONNECTION_FAILED` and friends as they happen, with a timestamp.
- **Report the app's state.** Port, whether an engine is listening, and whether the root CA is
  trusted, read live from the app over native messaging.
- **Capture localhost.** Chromium's `<-loopback>` bypass-list entry is the only way to send
  `localhost` to the proxy, and it is the **Capture localhost** checkbox.

Firefox uses `proxy.onRequest` to route requests for websites the user allows. Normal-window
capture needs website access, not private-window access. Turning capture off leaves the
browser's existing proxy configuration in place.

## What it explicitly does not do

| Not possible | Why |
|---|---|
| Install or trust the CA | OS keychain work. That is the app's Certificates pane. |
| Disable QUIC | `chrome://flags` and managed policy are out of an extension's reach. Chrome already refuses QUIC to a non-QUIC proxy, so forcing the proxy covers Chrome; other apps are the app's problem. |
| Restart the browser | No API. The popup says to reload instead. |
| Defeat certificate pinning | Not exposed to extensions, and not defeatable by any CA install. |
| Read bodies | Decryption is the proxy's job. The extension never sees request content. |

## Build and load

```sh
Scripts/build-browser-extension.sh
# Chromium: Resources/browser/proxymaxx-extension/
# Firefox:  Resources/browser/proxymaxx-firefox-extension.xpi
Scripts/bundle-app.sh
```

Open **ProxyMaxx → Install Browser Extension…**. The app installs native host manifests
for Chromium and Firefox profiles it finds, then copies both artifacts into
`~/Library/Application Support/ProxyMaxx/Browser Extension/`. The sheet provides
**Copy Path**, **Open in Finder**, and separate installation steps for each browser.
Open the browser once before installing the bridge so its profile exists.

### Chromium

Open `chrome://extensions`, enable **Developer mode**, choose **Load unpacked**, and select
the `proxymaxx-extension` subfolder. After rebuilding, press **Reload** on its card.

### Firefox: local development

1. Open `about:debugging#/runtime/this-firefox` and choose **Load Temporary Add-on…**.
2. Select `proxymaxx-firefox-extension.xpi` from the folder shown by the app, or directly
   from `Resources/browser/` when working in this checkout.
3. Start ProxyMaxx or `proxymaxx-cli serve`, install and trust its root CA, then click
   **Capture this browser**. Allow website access if Firefox asks. Normal-window capture
   does not require **Run in Private Windows**.
   If Firefox still rejects HTTPS certificates, import the exported CA under Firefox's
   **Settings → Privacy & Security → Certificates → View Certificates → Authorities**,
   trusting it to identify websites.

The local XPI is unsigned. Temporary installation lasts until Firefox exits; use **Reload**
under ProxyMaxx in `about:debugging` after rebuilding. It is not a permanently installable
release package just because its filename ends in `.xpi`.

### Firefox: permanent installation

Standard Firefox requires a [Mozilla-signed add-on](https://extensionworkshop.com/documentation/publish/signing-and-distribution-overview/).
Submit the generated XPI to [Mozilla Add-ons](https://addons.mozilla.org/developers/) for
self-distribution (unlisted), then download the signed XPI. Signing requires the
maintainer's Mozilla account and approval; this build script does not sign add-ons.

To include that signed file without changing its bytes:

```sh
Scripts/build-browser-extension.sh --firefox-xpi /path/to/mozilla-signed.xpi
Scripts/bundle-app.sh debug --firefox-xpi /path/to/mozilla-signed.xpi
# Release bundles also need --with-android-vpn.
```

The supplied package must match this checkout's Firefox ID, version and runtime files.
The script checks for signing metadata; Firefox verifies the cryptographic signature.
Pass the flag when bundling too: an ordinary build regenerates the unsigned development XPI.

In Firefox, open `about:addons`, use the gear menu's **Install Add-on From File…**, and select
the signed XPI. Allow website access when prompted, then start ProxyMaxx and enable capture.

### Firefox: optional private-window capture

Private-window access is optional. To include private windows, open `about:addons`, select
**Extensions** in the sidebar, then **ProxyMaxx → Details → Run in Private Windows → Allow**.
Without that permission, this extension only routes normal-window requests. An existing
Firefox or system proxy can still route private-window traffic independently.

### Firefox: connection troubleshooting

Firefox's extension menu may say **Can't read and change data on this site**. Request-level
capture requires website access. Click **Capture this browser** and approve Firefox's
website-access prompt if it appears. The extension uses that permission for request routing;
it does not inject page scripts. Firefox's own restrictions still apply to extension access.

**No such native application com.proxymaxx.browser** means Firefox cannot find the native
host registration. On macOS, the per-user manifest belongs at
`~/Library/Application Support/Mozilla/NativeMessagingHosts/com.proxymaxx.browser.json`,
not under `Firefox/NativeMessagingHosts`. Firefox profiles still live under
`~/Library/Application Support/Firefox`; the two directories serve different purposes.
See Mozilla's [native manifest locations](https://developer.mozilla.org/en-US/docs/Mozilla/Add-ons/WebExtensions/Native_manifests#macos).

After updating the app, run **ProxyMaxx → Install Browser Extension…** again. Reload the
temporary add-on in `about:debugging#/runtime/this-firefox`, or restart Firefox for a
permanently installed add-on, then press **Check again**. Start the proxy before turning
capture on; the port should come from the app once the bridge answers.

## Order matters, and why

Enabling capture points every request in that browser at a loopback port. If nothing is
listening there, the browser cannot load anything at all. Start the proxy, trust its CA,
then enable capture. A missing native bridge does not prove that the proxy is stopped;
the popup distinguishes those cases.

## Limits, stated plainly

- **Safari is unsupported.** Safari has no proxy API and is not wired up.
- **Firefox request routing.** `proxy.onRequest` selects the local HTTP proxy for requests
  covered by the extension's website permission. Revoking website access suspends routing;
  turning capture off leaves Firefox, system, and other extension proxy settings unchanged.
  Only requests Firefox exposes to the extension can be routed this way.
- **Firefox proxy failures.** Active capture does not silently fall back to the browser's
  underlying proxy when the capture proxy is unavailable. Turn capture off to restore the
  browser's normal routing.
- **Firefox errors.** `proxy.onError` reports request-routing configuration failures, not
  every connection failure. Listener availability comes from the native bridge.
- **The extension cannot see the OS proxy.** In `system` mode, Chromium reports the mode
  and control level, not the resolved server address.
- **Chromium's `--proxy-server` wins.** A browser launched with that flag ignores
  `chrome.proxy` settings.
- **No icons yet.** The toolbar shows the default extension icon.
- **It cannot verify the CA itself.** The CA verdict comes from the app; when the bridge
  is unavailable, the popup reports unknown. Firefox's own CA trust can differ.
- **It is not a capture engine.** It configures and diagnoses; the proxy captures.

## Reference

The app or `proxymaxx-cli serve` writes
`~/Library/Application Support/ProxyMaxx/browser-bridge.json` when engine state changes
and marks it stopped on exit. The native host answers from that file, so the extension
follows the active engine's port regardless of which front end owns it.

| Field | Type | Meaning |
|---|---|---|
| `version` | int | schema version, currently `1` |
| `httpPort` | int | the proxy's HTTP port |
| `socksPort` | int? | the SOCKS5 port, when this app hosts the engine |
| `running` | bool | an engine is listening, this app's or the CLI's |
| `caTrusted` | bool | the root CA is trusted for SSL |
| `systemProxy` | bool | the macOS system proxy points here |

| Name | Value |
|---|---|
| Native messaging host | `com.proxymaxx.browser` |
| Host binary | `proxymaxx-browser-host`, beside the app binary |
| Chromium extension ID | `cbmoimaniepmlkjbkdpeoeflbhaefeae` |
| Firefox add-on ID | `proxy@proxymaxx.app` |

Chromium derives its extension ID from `key` in
`Browser/ProxyMaxxExtension/manifest.json`. The build checks it against
`BrowserBridge.extensionID` so the native host authorizes the same origin.

Firefox pins its ID in `browser_specific_settings.gecko.id`; its native host manifest uses
`allowed_extensions`, not Chromium's `allowed_origins`. The build verifies this identity too.
