# ProxyMaxx

A native macOS HTTP/HTTPS debugging proxy: intercept, decrypt, inspect and (soon)
rewrite traffic. There is **no licence key and no paid tier** — every feature here
is present because the code is in this repository.

## Status — Phase 1 complete

Working today:

- HTTP/1.1 proxy on `127.0.0.1:9090` with CONNECT tunnelling.
- HTTPS man-in-the-middle: a local root CA signs a per-host leaf certificate;
  decrypted requests/responses are captured and shown.
- Opaque tunnelling for hosts excluded from SSL Proxying (byte-for-byte relay,
  no interception).
- Live traffic table (method, status, host, path, size, duration, client) with
  text/method/error filtering.
- Flow inspector: request/response headers, pretty/raw/hex bodies, JSON and form
  formatting, image preview, timings, decryption state.
- SSL Proxying list (include/exclude wildcards).
- **WebSocket**: after a `101 Switching Protocols` the connection is handed to a raw relay,
  so long-lived sockets (chat, huddles, live updates) keep working through the proxy. Text,
  binary and control frames are recorded on the upgrade flow and listed in the inspector;
  payloads compressed by `permessage-deflate` are forwarded untouched and shown as hex.
- **Map Local**: answer a matched request from a local file or directory instead of the
  network. A file is served either as a whole HTTP/1.x message (status, headers and body)
  or as a plain body with the content type inferred from its extension; a directory
  answers the request path and falls back to `index.html`. Rules match by Contains,
  Match Wildcard, Match Regex (full-match) or Exact, optionally filtered by method, and
  can delay the response. Rules are evaluated top to bottom and the first match wins.
  A rule whose file or directory is gone falls through to the remote server.
- One-click certificate install into the System keychain, CA export.
- System proxy enable/disable for all network services.
- A **SOCKS5 listener on `127.0.0.1:8989`** for clients that will not use the system proxy —
  the bundled [Android tunnel](Android/README.md) reaches the proxy this way. Change the port
  in Settings; if it is taken, the listener re-selects one and says so.
- A **Chromium browser companion** ([Browser/README.md](Browser/README.md)): an extension that
  points a browser at the proxy through `chrome.proxy` — including when a policy, another
  extension or a command-line flag is overriding the system proxy — and then names which of
  the usual blockers (CA trust, loopback, HTTP/3, a foreign proxy owner) is still in the way.
- **Android setup, one click**: install the CA as a system certificate, set the device's proxy,
  and install and launch the [tunnel app](docs/android.md). Works on Google APIs emulators via
  `adb root`, and on Google Play AVDs through a bundled, consent-based
  [Magisk route](Resources/android/README.md) — with a
  [device guide](docs/android.md) for physical phones.
- Verified end to end by integration tests that drive the proxy with real `curl`.

Not yet implemented (planned, in order): Map Remote, Breakpoint, Scripting
(JavaScriptCore), Allow/Block list, DNS Spoofing, Network Throttling, Reverse
Proxy, External/SOCKS proxy, Compose, Diff, GraphQL/Protobuf, HTTP/2,
code generation, HAR import/export, MCP server.

## Build and run

```sh
swift build                       # compile everything
swift test                        # unit + end-to-end proxy tests
Scripts/bundle-app.sh             # produce dist/ProxyMaxx.app
open "dist/ProxyMaxx.app"
```

`Scripts/bundle-app.sh` builds the companions before it packages anything: the CLI, the
browser extension, and — when asked — the Android tunnel. Their staged copies under
`Resources/` are gitignored on purpose, so a stale artifact cannot be bundled by accident.
The tunnel is opt-in because its Gradle build needs a JDK and the Android SDK; a release
bundle fails outright if it is missing.

```sh
Scripts/bundle-app.sh release --with-android-vpn   # local release bundle
Scripts/build-all.sh release                       # the same thing, for CI
```

### Releases

Pushing a `vX.Y.Z` tag runs [`.github/workflows/release.yml`](.github/workflows/release.yml),
which builds the bundle on macOS and publishes `ProxyMaxx-vX.Y.Z.dmg` — mount it, drag
ProxyMaxx to Applications. The Android tunnel travels inside the app, so it is not a
separate download; it is signed from the `KEYSTORE_BASE64`, `STORE_PASSWORD`, `KEY_ALIAS`
and `KEY_PASSWORD` repository secrets. Without them the run still succeeds with an unsigned,
emulator-only tunnel.

#### Homebrew

```sh
brew tap AgiMaulana/proxymaxx
brew trust --tap agimaulana/proxymaxx
brew install --cask AgiMaulana/proxymaxx/proxymaxx
```

`brew trust` is needed once, because Homebrew refuses to load a cask from a tap that is not in
its trust list. The cask clears the quarantine attribute on the app it installs, so ProxyMaxx
opens without Gatekeeper complaining.

The tap lives at [AgiMaulana/homebrew-proxymaxx](https://github.com/AgiMaulana/homebrew-proxymaxx).
Its `Casks/proxymaxx.rb` is generated — edit
[`Scripts/homebrew/proxymaxx.rb`](Scripts/homebrew/proxymaxx.rb) instead, and the `tap` job in
`release.yml` renders and pushes it on every tag.

To build a signed release locally, keep the keystore and its credentials out of the checkout
and read them through `xenv`:

```sh
xenv -i .env.keystore inject ALIAS PASSWORD -- sh -c '
  STORE_FILE="$PWD/Colonyx.jks" STORE_PASSWORD="$PASSWORD" \
  KEY_ALIAS="$ALIAS" KEY_PASSWORD="$PASSWORD" Scripts/build-all.sh release'
```

Installing from the DMG is the other route: mount it and drag ProxyMaxx to Applications. The
`.app` is ad-hoc signed, so macOS quarantines that copy and Gatekeeper refuses the first
launch. Homebrew quarantines its downloads too, which is why the cask clears the attribute
itself; for a DMG install, clear it once by hand:

```sh
xattr -dr com.apple.quarantine "/Applications/ProxyMaxx.app"
```

Or run straight from SwiftPM during development:

```sh
Scripts/run.sh                                    # opens the window
Scripts/run.sh debug --autostart --port 9090      # start listening immediately
```

Use `Scripts/run.sh` rather than `swift run`: SwiftUI reads `Localizable.strings` from
the app bundle, and an unbundled `swift run` binary has no `.lproj` folder, so it would
show the symbolic keys instead of English. The runner copies the localizations beside
the binary first.

### Localization

The UI is localized with Apple's standard `Localizable.strings`. English is the source
language and lives in [`Resources/en.lproj/Localizable.strings`](Resources/en.lproj/Localizable.strings).
The keys are short, stable identifiers (`main.systemProxy`, `inspector.responseHeaders`), and
the English copy is the value. Code that builds text at runtime passes an English default,
so tests and command-line paths still read in English when no bundle is present.

To add a language, copy that file to `Resources/<language>.lproj/Localizable.strings`,
translate the values (keep the keys and any `%@` / `%lld` placeholders), and rebuild with
`Scripts/bundle-app.sh`. The bundler copies every `Resources/*.lproj` directory it finds.
Activity-log lines and Android installer output stay in English because they are
diagnostics, not UI copy.

The headless companion CLI (`proxymaxx-cli`) drives the same engine and rules, for scripts and
AI agents. `serve` starts the proxy, `flows` reads the captured session with the same
filters as the window, and `stop` shuts it down:

```sh
Scripts/build-cli.sh                            # -> Resources/proxymaxx-cli
proxymaxx-cli serve --detach --port 9090         # fire-and-forget; returns at once
proxymaxx-cli flows --host api.example.com --method POST
proxymaxx-cli stop
```

`Scripts/bundle-app.sh` rebuilds and copies the binary into the bundle, so after installing
the app the same tool runs from `ProxyMaxx.app/Contents/Resources/proxymaxx-cli` without the
checkout.
The app's **ProxyMaxx → Command Line Tool…** menu shows that path with **Copy Path** and
**Open in Finder**.

See [cli/README.md](cli/README.md) for the full surface.

## Use it

1. Launch the app and press **Start**.
2. Open **Certificates** and click **Install & Trust Certificate** (one admin
   prompt). This trusts the generated root CA so browsers accept intercepted
   connections.
3. Either toggle **System Proxy** (all network services) or point a client at it
   directly:

   ```sh
   curl --proxy http://127.0.0.1:9090 http://example.com/
   curl --proxy http://127.0.0.1:9090 --cacert <exported-ca>.crt https://example.com/
   ```

4. Traffic appears in the table; select a row to inspect it.
5. Add hosts to **SSL Proxying → Exclude** to leave their TLS untouched.
6. Open **Map Local** (or press ⌘L) to answer matched URLs from a local file or
   directory. Add a rule, set its URL and matching style, then pick the file or
   directory under **Map To**.

## Privileged operations (CA trust, system proxy)

**Neither operation needs administrator rights, a password, or a privileged helper.**
Nothing is installed outside `~/Library`. Just click **Certificates → Install & Trust
Certificate**.

Why that works, and why the obvious approaches do not:

- Trust settings live in two domains with different rules:
  ```
  com.apple.trust-settings.admin  ->  [entitled, authenticate-admin]
  com.apple.trust-settings.user   ->  [entitled-session-owner-or-authenticate-session-owner]
  ```
  The admin domain needs an Apple-private entitlement or an *interactive* admin
  authentication. **Being root satisfies neither** — which is why a root daemon attempting
  it reports `The authorization was denied since no user interaction was possible`. A
  privileged helper is therefore useless for certificate trust, and ProxyMaxx does not
  install one.
- The user domain needs only the logged-in owner, so the app can write it directly.
- `networksetup -setwebproxy` likewise applies as the logged-in user.

The app runs `security add-trusted-cert -r trustRoot -k <user keychain>` directly, with
no helper and no elevated prompt. A privileged helper exists **for the proxy only**.

Two deliberate choices in how trust is applied:

- Trust is scoped with `-p ssl -p basic` rather than granted to every policy.
- Certificates are deleted by listing SHA-1 hashes and deleting each in Swift, rather
  than piping through `awk`/`sh`, so a common name can never reach a shell.

An optional **Certificates → Authorise certificate changes with Touch ID** adds a biometric
confirmation. It is a convenience, not a gate: no authorization is actually required.

If a locked-down configuration ever refuses, the app escalates to a single authorised
prompt rather than failing.

## Safety around the system proxy

Turning the system proxy on redirects *all* HTTP/HTTPS traffic on the machine here, so
the two ways that can go wrong are handled explicitly:

- **The root certificate must be trusted first.** Enabling the system proxy is refused
  until the CA is installed; otherwise every HTTPS client rejects the intercepted
  certificate (`CERTIFICATE_UNKNOWN`) and networking appears broken.
- **The setting is put back on exit.** Quitting restores the previous system proxy — with
  no privileges needed, this happens instantly and silently, including on Cmd+Q.
- **Leftovers are detected and repairable.** If a previous run was killed without
  shutting down, the app notices the stale setting on launch and offers a one-click
  **Restore**.
- **Port conflicts are reported.** If something else already listens on the port (for
  example a previous ProxyMaxx run on 9090), the app says so instead of half-binding on top of
  it. Change the port in **Settings**.

If networking is ever broken after a crash, clear it from a terminal:

```sh
sudo networksetup -setwebproxystate "Wi-Fi" off
sudo networksetup -setsecurewebproxystate "Wi-Fi" off
```

## Architecture

```
Sources/
  FlowKit      Flow/HTTP models, MIME parsing, body formatting, FlowStore
  CertKit      Root CA + per-host leaf generation, caching, on-disk storage
  RuleKit      Wildcard matching, MatchingRule, SSLProxyingPolicy, Map Local rules, RuleStore
  ProxyKit     NIO proxy engine: CONNECT, TLS MITM, opaque relay, flow recording
  SystemKit    networksetup system proxy, certificate trust, the browser bridge
  CodeGenKit   (scaffold for request code generation)
  BrowserHost  the browser companion's native messaging host
  ProxyMaxxApp  SwiftUI app
Tests/
  CertKitTests      certificate chain validated with SecTrust
  RuleKitTests      matching rules and Map Local matching, file and directory resolution
  ProxyKitTests     end-to-end MITM, opaque tunnel, plain HTTP and Map Local via curl
```

### How the MITM works

On `CONNECT host:port` the proxy acknowledges the tunnel, then — for hosts the
SSL Proxying policy says to decrypt — inserts a TLS server handler carrying a
leaf certificate for `host` at the head of the connection pipeline and switches
into tunnel mode. That certificate is signed by the local root CA, which the
user has trusted, so the client completes its handshake with the proxy. The
proxy then opens its own TLS connection upstream and relays the decrypted
request/response, recording both as a `Flow`.

Two NIO details this design depends on, both covered by tests:

- `HTTPRequestDecoder`/`HTTPResponseDecoder` are **write-observing** codecs, so
  they must sit *after* their encoder in pipeline order.
- NIO's decoder stops parsing permanently after a `CONNECT` (it is treated as an
  upgrade), so the codec is replaced while the tunnel handler is retained.

## License

MIT — see [LICENSE](LICENSE).
