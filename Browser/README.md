# ProxyMaxx, the browser side

A Chromium extension that makes a browser actually use the proxy, and then reports which of
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
Scripts/build-browser-extension.sh   # -> Resources/browser/proxymaxx-extension/
Scripts/bundle-app.sh                # copies it, and the host, into the .app
```

Then, once per browser:

1. Open the app's **ProxyMaxx → Install Browser Extension…** menu item. It writes the host
   manifests for every Chromium browser it finds, copies the extension to
   `~/Library/Application Support/ProxyMaxx/Browser Extension/`, and opens a panel with that
   path, a **Copy Path** action, and **Open in Finder**. The panel also names the browsers it
   reached, or says none were found; the manifests themselves are invisible.
2. In the browser, open `chrome://extensions`, turn on **Developer mode**, choose
   **Load unpacked**, and pick `proxymaxx-extension` from that folder.
3. Start the app or `proxymaxx-cli serve`, and confirm the port. The extension follows
   whatever port the engine owner reports, the app's or the CLI's, so the two cannot drift
   apart.
4. Install and trust the root CA in the app, then turn **Capture this browser** on.

A policy-managed browser will refuse step 4. The popup says so by name instead of failing
quietly, which is the whole point of reporting `levelOfControl`.

## Order matters, and why

Enabling capture points every request in that browser at a loopback port. If nothing is
listening there, the browser cannot load anything at all. So the sequence is: app running and
serving, then trust the CA, then capture on. The extension reports its own uncertainty rather
than asserting the app is down, because "the app cannot be reached" and "nothing is listening"
are different states, and only the native host can tell them apart, because only it can open a
socket to the port.

## Limits, stated plainly

- **Chromium only.** Firefox's `browser.proxy` is a different API with a different permission
  model, and Safari has no proxy API at all. Neither is wired up.
- **The extension cannot see the OS proxy.** In `system` mode, `chrome.proxy.settings.get`
  returns the mode and control level but not the resolved server, so the popup reports
  "system" rather than the address. There is no API that exposes it.
- **`--proxy-server` wins.** A browser launched with it ignores `chrome.proxy` entirely,
  which is exactly the kind of override the owner report exists to surface.
- **No icons yet.** The toolbar shows the default extension icon.
- **It cannot verify the CA itself.** The CA verdict comes from the app's trust check over the
  bridge; when the app is not running, the popup says "unknown" rather than guessing.
- **It is not a capture engine.** It configures and diagnoses; the proxy captures.

## Reference

Whoever owns the engine, the app or `proxymaxx-cli serve`, writes
`~/Library/Application Support/ProxyMaxx/browser-bridge.json` on every state change while it
serves, and marks it stopped on the way out. The host answers the extension from that file, so
the host is stateless. A CLI-owned engine is not a second-class case: it publishes the same
file, so the extension follows its port exactly as it follows the app's.

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
| Extension ID | `cbmoimaniepmlkjbkdpeoeflbhaefeae` |

The extension ID is not assigned by the store: it is derived from `key` in
`Browser/ProxyMaxxExtension/manifest.json`, so it is stable across machines and the host
manifest can whitelist it. `Scripts/build-browser-extension.sh` re-derives it and fails if it
ever disagrees with `BrowserBridge.extensionID`.
