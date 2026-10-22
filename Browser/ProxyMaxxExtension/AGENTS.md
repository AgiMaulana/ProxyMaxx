# Memory

## Project Overview
The Chromium half of the ProxyMaxx browser companion: a Manifest V3 extension that
points a browser at the local proxy and reports what still stops capture. The macOS half
is `Sources/BrowserHost` (the native messaging host) and `Sources/SystemKit/BrowserBridge.swift`.
See `../README.md` for the contract, the build, and the limits.

## Code Style Guidelines
- Use descriptive variable names
- Follow existing patterns in the codebase
- Extract complex conditions into meaningful boolean variables
- Comments state the reason a thing is the way it is, not what the line does

## Architecture Notes
- **The service worker owns the proxy setting; the popup only renders.** Every verdict in
  the popup comes from `chrome.proxy.settings.get()` or the app's state file — never from
  an assumption about what should be true.
- **Registration order is load-bearing.** `chrome.runtime.onMessage` is registered before
  anything else and unconditionally. If the worker throws while evaluating, it never
  registers and the popup sees "Receiving end does not exist" — a blank panel with no
  explanation. Every other event registration goes through `registerSafely`, which records
  the failure in `chrome.storage.local.initFailure` for the popup to display. Do not add a
  bare top-level `addListener` above the message channel.
- **A page that never loads its script fails in total silence.** `popup.html` must contain
  `<script src="popup.js"></script>`. Without it the panel renders its placeholder, the
  extension reports no error anywhere, and the worker is simply never messaged — which
  looks identical to a broken worker. `Scripts/build-browser-extension.sh` fails the build
  if popup.html references a file that does not exist, or if any `.js` in the folder is
  loaded by neither popup.html nor the manifest. Never remove that check.
- **The popup degrades instead of blanking.** When the worker is unreachable, the popup
  reads the proxy setting and its own storage directly and shows the reason. A diagnostics
  panel that shows nothing is worse than one that shows less.
- **Native messaging is one question at a time.** `askApp()` connects, sends `hello`, waits
  for one reply, and disconnects. Native ports and MV3 service workers suspend at different
  times; a long-lived port is a bug waiting to happen, and the state is cheap to re-read.
- **A missing native host is not an error.** It is the normal state before the app writes
  its manifests, so it renders as a plain reason, not a failure.
- **Disable means `clear`, not restore.** Clearing the extension's own level returns the
  browser to whatever it did before the extension had an opinion, which is more honest than
  replaying a snapshot that may already be stale.
- **The extension ID is fixed by `key` in `manifest.json`.** The native messaging host
  whitelists `chrome-extension://<id>/`, so the ID must never drift.
  `Scripts/build-browser-extension.sh` verifies it against `BrowserBridge.extensionID`.

## Common Workflows
- Package: `Scripts/build-browser-extension.sh` → `Resources/browser/proxymaxx-extension/`
- Load: `chrome://extensions` → Developer mode → Load unpacked, from
  `~/Library/Application Support/ProxyMaxx/Browser Extension/proxymaxx-extension`, which
  is where the app's install menu item copies the built extension
- Full bundle: `Scripts/bundle-app.sh`, then the app's **Install & Reveal Browser Extension**
