# Browser companion resources

What the macOS app bundles for the browser companion. Nothing here is a source of truth:
everything is written by `Scripts/build-browser-extension.sh` from
[`Browser/ProxyMaxxExtension`](../../Browser/ProxyMaxxExtension) and [`Browser/FirefoxExtension`](../../Browser/FirefoxExtension), and the app reads it from
`Contents/Resources/Browser` after `Scripts/bundle-app.sh` copies it in.

| Path | What |
|---|---|
| `proxymaxx-extension/` | The unpacked extension, as built. `bundle-app.sh` copies it into `Contents/Resources/Browser`; the app's install menu item copies it on from there to `~/Library/Application Support/ProxyMaxx/Browser Extension/proxymaxx-extension`, which is the path a browser's "Load unpacked" points at. |
| `proxymaxx-firefox-extension.xpi` | The Firefox package, with `manifest.json` at the archive root. The app copies it to `~/Library/Application Support/ProxyMaxx/Browser Extension/proxymaxx-firefox-extension.xpi`; its installation sheet explains temporary and signed installation. |

Both artifacts are gitignored. A fresh clone has neither until the build script runs;
`Scripts/bundle-app.sh` runs it automatically. Firefox builds are unsigned by default,
for **Load Temporary Add-on…** in `about:debugging`. Permanent installation requires a
Mozilla-signed XPI; see [build and load](../../Browser/README.md#build-and-load).

The install location is outside the `.app` on purpose. Finder will not reveal a path inside an
application bundle, since it selects the bundle itself, and a browser remembers the folder it
loaded, so it must not be somewhere the next `bundle-app.sh` replaces.

The native messaging host binary does **not** live here. It has to sit beside the app binary in
`Contents/MacOS/`, because the host manifest each browser reads names an absolute path and the app
points it there at install time.

Without a built extension the app still runs: the install menu item reports that the extension
has not been built, and the extension, if a browser already has it loaded, falls back to its own
port field and reports "App not running" instead of a live state.

Build them with:

```sh
Scripts/build-browser-extension.sh
Scripts/bundle-app.sh
```

To preserve a Mozilla-signed XPI that matches this checkout, pass
`--firefox-xpi /path/to/mozilla-signed.xpi` to either script. Bundling without that option
rebuilds the unsigned XPI. The build checks runtime bytes and signing metadata; Firefox
performs signature verification.
