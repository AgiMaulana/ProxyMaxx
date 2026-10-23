# Browser companion resources

What the macOS app bundles for the browser companion. Nothing here is a source of truth:
everything is written by `Scripts/build-browser-extension.sh` from
[`Browser/ProxyMaxxExtension`](../../Browser/ProxyMaxxExtension), and the app reads it from
`Contents/Resources/Browser` after `Scripts/bundle-app.sh` copies it in.

| Path | What |
|---|---|
| `proxymaxx-extension/` | The unpacked extension, as built. `bundle-app.sh` copies it into `Contents/Resources/Browser`; the app's install menu item copies it on from there to `~/Library/Application Support/ProxyMaxx/Browser Extension/proxymaxx-extension`, which is the path a browser's "Load unpacked" points at. |

The staged folder is gitignored, like the Android tunnel APK, so a stale copy cannot be
bundled by accident. A fresh clone has no `proxymaxx-extension/` until the build script runs,
and `Scripts/bundle-app.sh` runs it for you.

The install location is outside the `.app` on purpose. Finder will not reveal a path inside an
application bundle, since it selects the bundle itself, and a browser remembers the folder it
loaded, so it must not be somewhere the next `bundle-app.sh` replaces.

The native messaging host binary does **not** live here. It has to sit beside the app binary in
`Contents/MacOS/`, because the host manifest Chrome reads names an absolute path and the app
points it there at install time.

Without a built extension the app still runs: the install menu item reports that the extension
has not been built, and the extension, if a browser already has it loaded, falls back to its own
port field and reports "App not running" instead of a live state.

Build them with:

```sh
Scripts/build-browser-extension.sh
Scripts/bundle-app.sh
```
