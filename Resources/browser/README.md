# Browser companion resources

What the macOS app bundles for the browser companion. Nothing here is a source of truth:
everything is written by `Scripts/build-browser-extension.sh`, and the app reads it from
`Contents/Resources/Browser` after `Scripts/bundle-app.sh` copies it in.

| Path | What |
|---|---|
| `proxymaxx-extension/` | The unpacked extension, as built. `bundle-app.sh` copies it into `Contents/Resources/Browser`; the app's install menu item copies it on from there to `~/Library/Application Support/ProxyMaxx/Browser Extension/proxymaxx-extension`, which is the path a browser's "Load unpacked" points at. |

The install location is outside the `.app` on purpose. Finder will not reveal a path inside
an application bundle — it selects the bundle itself — and a browser remembers the folder it
loaded, so it must not be somewhere the next `bundle-app.sh` replaces.

Like `Resources/android/proxymaxx-vpn.apk`, this artifact is committed so the app ships
complete. It is a byte-for-byte copy of `Browser/ProxyMaxxExtension/` with `AGENTS.md`
removed, so `Scripts/build-browser-extension.sh` reproduces it exactly and prints a digest
of the staging tree.

The native messaging host binary does **not** live here. It has to sit beside the app
binary in `Contents/MacOS/`, because the host manifest Chrome reads names an absolute
path and the app points it there at install time.

If either file is missing, the app still runs: the menu item reports that the extension
has not been built, and the extension — if a browser already has it loaded — falls back
to its own port field and reports "App not running" instead of a live state.

Build them with:

```sh
Scripts/build-browser-extension.sh
Scripts/bundle-app.sh
```
