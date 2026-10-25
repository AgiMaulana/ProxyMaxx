# proxymaxx-cli

The shell front-end of ProxyMaxx. It drives the same proxy, the same rules and the same
captured traffic as the Mac app, so an AI agent can work from a terminal while a person watches
in the window.

The app and this CLI are one tool with two ways to drive it. They share these files under
`~/Library/Application Support/ProxyMaxx/`:

- `rules.json` holds the Map Local and SSL Proxying rules.
- `proxy-registry.json` names the process that currently runs the engine.
- `ipc/` carries live commands, and `ipc/flows/` carries captured flows between the two
  front-ends.
- `session.ndjson` is the append-only record of the current session: one JSON flow per line,
  written by whoever hosts the engine, never deleted by a reader. `proxymaxx-cli flows` reads
  it, so capture outlives the process that produced it.
- `browser-bridge.json` tells the browser companion which port the engine listens on. Whichever
  side owns the engine publishes it, so the extension follows a CLI-run proxy exactly as it
  follows the app's.

Only one process runs the engine at a time. Whichever starts first becomes the host and records
itself in the registry; the other attaches to it. Attaching is not a degraded mode: the host
publishes every captured flow into `ipc/flows/`, so the app shows CLI traffic live and the CLI
reads app traffic the same way. "Host here instead" in the app (or `proxymaxx-cli serve` when
the app is idle) just moves the engine role, it does not change what either side can see.

## Build

```sh
swift build --product proxymaxx-cli
# binary: the path from `swift build --show-bin-path`
# or: Scripts/build-cli.sh  ->  Resources/proxymaxx-cli
```

`Scripts/bundle-app.sh` copies that artifact into the app, so an installed copy runs from
inside the bundle:

```sh
/Applications/ProxyMaxx.app/Contents/Resources/proxymaxx-cli status
```

The source checkout is not needed at that point: the bundled binary is the same one the build
just produced. In the app, **ProxyMaxx → Command Line Tool…** shows that path with **Copy
Path** and **Open in Finder**.

## Commands

```sh
proxymaxx-cli serve  [--port N] [--socks-port N] [--rules PATH] [--flow-mode summary|full]
                     [--out PATH] [--detach]
proxymaxx-cli stop   [--force]
proxymaxx-cli flows  [--filter TEXT] [--method M] [--errors-only] [--host H] [--app A]
                     [--pinned] [--saved] [--since 30s|5m|2h|1d] [--limit N]
                     [--flow-mode summary|full] [--out PATH] [--follow] [--text]
                     [--fail-on-match]
proxymaxx-cli status
proxymaxx-cli proxy on | off | status
proxymaxx-cli proxy-host
proxymaxx-cli maplocal on | off
proxymaxx-cli clear-session
proxymaxx-cli paths
```

`serve` runs the engine headless. It refuses to start when an engine is already up (exit code
`3`) so agents can fall back to attach mode instead of fighting over the port.

`serve --detach` starts the engine in the background and returns immediately (exit `0`, with a
status object on stdout): the fire-and-forget form for an agent, without a second verb that
starts the engine. Every other flag is inherited by the background process, and its stdout
stream is discarded, so flows go to the session log instead. Diagnostics land in `serve.log`
beside it. `proxymaxx-cli stop` stops whichever process owns the engine, CLI or app, and is
idempotent: stopping when nothing runs still succeeds.

`flows` reads the session log and prints one flow per line, narrowed exactly like the app's
filter bar. `--follow` tails new flows until interrupted or the engine stops; `--text` prints a
human line instead of the NDJSON object `serve` streams. A flow is printed once, when it
closes: the log holds every snapshot the engine emits (request, response head, throttled body,
completion), and `--follow` waits for the closing one so the line carries its body and
duration, exactly as `flows` would print it afterwards. A flow still open when the engine stops
is printed from its latest snapshot. The filter flags map one-to-one onto the app's menu:

| App filter | Flag |
|------------|------|
| Filter text | `--filter TEXT` (matches url, host, method, status) |
| Method | `--method GET|POST|...` |
| Errors only | `--errors-only` |
| Domain | `--host api.example.com` |
| App | `--app com.example.app` |
| Pinned | `--pinned` |
| Saved | `--saved` |

`--host`, `--app`, `--pinned` and `--saved` all describe one sidebar choice, so at most one
may be given. `--since` takes a duration or seconds; `--limit` keeps the newest N flows, and
with `--follow` it stops after N flows.

`--fail-on-match` prints every selected flow, then exits `4` if at least one matched. No
matches exit `0`; command and input failures keep their existing exit codes. Combine it with
`--errors-only` to fail CI on HTTP 4xx/5xx responses or transport errors while retaining the
NDJSON diagnostics:

```sh
proxymaxx-cli flows --out "$LOG" --errors-only --flow-mode full --fail-on-match \
  > failing-flows.ndjson
```

Rules come in two surfaces that write the same file.

The JSON surface, for a parser that already speaks the envelope:

```sh
proxymaxx-cli rules map-local    list | get <id> | create <url> | update <id> | delete <id>
                                 | enable [<id>] | disable [<id>]
proxymaxx-cli rules ssl-proxying list
    | create --list include|exclude --pattern P
    | delete --list include|exclude --pattern P
    | enable | disable
```

The short surface, for typing by hand:

```sh
proxymaxx-cli rule list [--rules PATH] [--text]
proxymaxx-cli rule add    --url PATTERN --file PATH [--method M] [--name NAME]
                          [--style contains|wildcard|regex|exact] [--host-only] [--delay SECONDS]
proxymaxx-cli rule remove  (--id UUID | --name NAME | --url PATTERN)
proxymaxx-cli rule enable  (--id UUID | --name NAME | --url PATTERN)
proxymaxx-cli rule disable (--id UUID | --name NAME | --url PATTERN)
proxymaxx-cli rule move    --id UUID --by (-1|1 ...)
proxymaxx-cli rule clear
```

### ZIP bundles

Share a self-contained collection of rules and response files with `bundle export`, then
import it on another machine or before an automated test run:

```sh
# Export all current overrides, or select rules by name, URL pattern or UUID.
proxymaxx-cli bundle export --name "Post Consultation" --output post-consultation.zip
proxymaxx-cli bundle export --include consultation,prescription --output selected.zip

# Import disabled, then activate, or import with --activate on a fresh configuration.
proxymaxx-cli bundle import post-consultation.zip
proxymaxx-cli bundle activate post-consultation
proxymaxx-cli bundle list --text
proxymaxx-cli bundle show post-consultation
proxymaxx-cli bundle export post-consultation --output edited-post-consultation.zip
proxymaxx-cli bundle deactivate post-consultation
proxymaxx-cli bundle remove post-consultation
```

Every bundle command accepts `--rules PATH`. An explicit path operates on that file;
otherwise commands use the GUI's live state when it hosts the proxy. Select imported bundles
by UUID, case-insensitive name, or an unambiguous filename-style name such as
`post-consultation` for “Post Consultation”. `list` emits NDJSON and `show` emits one JSON object.

Import defaults incoming rules to disabled and leaves existing switches alone.
`bundle import ZIP --activate` imports and activates in one transaction. Activation enables
the collection and Local Override, disabling every outside rule. Deactivation disables only
that collection's members. Removal deletes owned rules and managed response files; files
still used by ordinary overrides are kept. Editing a member does not detach it: later
exports include its current matching fields, response, and order.
Activation is rejected when a collection has no remaining rules; existing switches stay unchanged.

The ZIP contains `manifest.json` and `map-local/<rule UUID>/<response basename>`.
The manifest has `formatVersion: 1`, a bundle `id`, a `name`, and an `overrides` array using
the existing `MapLocalRule` schema. Each rule's `destination` contains a relative file or
directory path under `map-local/`. Directories include their complete contents. Full HTTP
response files retain status, headers and body; direct `FILE_URL` responses are materialized
so they no longer depend on the source machine. Import copies responses beside the rule file
under `local-override-bundles/<bundle UUID>/` and rewrites only the local destination paths.

Validation completes before configuration changes. Unsupported versions, malformed rules,
missing responses, traversal paths, symlinks, corrupt data, and duplicate bundle names,
bundle UUIDs or rule UUIDs are rejected. Re-import never silently replaces a collection;
remove it explicitly first. CLI export refuses an existing output path.
Format 1 accepts ordinary stored/deflated ZIPs, not encrypted, split or ZIP64 archives.
Limits are 10,000 entries, 512 MiB per response, 1 GiB total, and 4 MiB for the manifest.

The top-level JSON `import` and `export` commands below remain configuration transfers.
They contain local paths and are not portable response bundles.

`rules map-local create` and `update` take the response source and its shape:

```sh
proxymaxx-cli rules map-local create 'api.example.com/v1/*' --path /tmp/stub.json
#   --kind file|directory  --delay-ms N  --name N
#   --method M  --match wildcard|regex|contains|exact
#   --include-subpaths BOOL  --enabled BOOL  --input PATH|-
```

`--input` reads the rule from stdin or a file when a shell hand-typed command is awkward.

Certificates and transfer:

```sh
proxymaxx-cli cert status | install | uninstall | export --out PATH
proxymaxx-cli android devices
proxymaxx-cli android prepare [--serial S] [--mode auto|google-apis|manual]
                              [--magisk|--no-magisk] [--include-physical]
proxymaxx-cli android revert  [--serial S] [--magisk|--no-magisk] [--include-physical]
proxymaxx-cli export --output PATH [--mode all|enabledRules]
proxymaxx-cli import --input  PATH [--mode append|override]
```

Short options (`-o`, `-i`, `-m`) work alongside the long ones.

## Android setup

`android prepare` is the CLI form of the app's one-click emulator guide: it installs the
root CA as a system certificate, configures interception, and installs and launches the
tunnel app. It runs the same bundled installer script with the same arguments, so a device
prepared here is indistinguishable from one prepared in the window.

```sh
# The tunnel reaches the proxy over SOCKS5, so give the engine a SOCKS listener.
proxymaxx-cli serve --detach --socks-port 8989

# Pick the first emulator (or name one) and prepare it. Logs go to stderr.
proxymaxx-cli android prepare
proxymaxx-cli android prepare --serial emulator-5554 --mode auto

# Undo: clear the proxy, remove the certificate and tunnel, restore a Magisk AVD.
proxymaxx-cli android revert --serial emulator-5554
```

`prepare` targets the first emulator when `--serial` is omitted, else the first attached
device, the same choice the guide makes. It needs a running engine (the app's or
`serve`'s), because the tunnel and the device proxy point at it; with no engine it fails
with the command to start one. When the tunnel APK is bundled, the engine must also have a
SOCKS5 listener, since the installer skips the device's HTTP proxy in that case. A build
without the tunnel APK still installs the certificate and sets the HTTP proxy. A real phone
is only changed with `--include-physical`, even when `--serial` names it.

The route matches the guide:

| `--mode` | What runs |
|----------|-----------|
| `auto` (default) | `adb root` on a Google APIs image; the bundled Magisk route on a Play AVD when `--magisk` is allowed |
| `google-apis` | Only the `adb root` path; an unrootable AVD is reported, never patched |
| `manual` | Prints the exact installer command in `commandLine`; touches nothing |

`--magisk` is on by default, matching the app's toggle; `--no-magisk` restricts the run to
`adb root`. Revert uses `--no-magisk` the same way, skipping the Magisk restore. Each
command prints one JSON object (`action`, `ok`, `serial`, ports, `magisk`, `tunnel`, `log`)
and streams the installer's own log to stderr with a `[proxymaxx-cli] android:` prefix.

## JSON envelope

Every `rules` command answers with one JSON object:

```json
{"action":"list","api_version":1,"ok":true,"tool":"map-local","data":{}}
{"action":"list","api_version":1,"ok":false,"tool":"map-local","error":{"code":"app_not_running","message":"..."}}
```

Keys are sorted, so two runs over the same state produce identical bytes. A failed command
prints the error envelope and exits `1`.

## Typical agent loop

```sh
# 1. Start the engine in the background and walk away. Returns at once.
proxymaxx-cli serve --detach --port 9090
#    -> {"ok":true,"owner":"cli","pid":4242,"httpPort":9090}
#    Foreground form, when you want a pipeline instead:
#    proxymaxx-cli serve --port 9090 > /tmp/flows.ndjson

# 2. Ask questions of the session whenever you like; the engine keeps capturing.
proxymaxx-cli flows --host api.example.com --method POST --limit 20
proxymaxx-cli flows --filter '/v1/user/profile' --flow-mode full

# 3. Save the stub body, then map the URL to it. The engine reloads without a restart.
cat > /tmp/stub-profile.json <<'EOF'
{ "id": 42, "name": "Stubbed Alice", "email": "stub@example.com" }
EOF
proxymaxx-cli rule add --url 'api.example.com/v1/user/profile' --file /tmp/stub-profile.json

# 4. Repeat the request. The flow reports mappedLocally=true and the rule name.
proxymaxx-cli flows --filter '/v1/user/profile'

# 5. Undo, then stop the engine.
proxymaxx-cli rule remove --url 'api.example.com/v1/user/profile'
proxymaxx-cli stop
```

`flows --follow` is the live form: it replays the session, then tails new flows until you
interrupt it or the engine stops. Each flow is printed once, from its closing snapshot. Because
the session log is plain NDJSON, `grep`, `jq` and the built-in filters work over the same file.

Open the Mac app at any point. It attaches to the running engine and shows the same flows,
because the host writes them into `ipc/flows/` as it captures them.

## Unsupported tools

These names are recognised but not implemented, so an agent that discovers them does not
mistake a missing feature for a crash. Each answers with an `unsupported` envelope and exits
`1`:

`map-remote`, `scripting`, `block-list`, `allow-list`, `reverse-proxy`,
`network-condition`, `no-caching`, `dns-spoofing`, `breakpoint`, `mcp`, `activate`,
`unlink`, `custom-cert`, `export-log`.

`activate` and `unlink` have no work to do here: this build has no licence key.

## Notes for agents

- stdout from `serve` is a machine stream, one JSON flow object per snapshot. Status and errors
  go to stderr with a `[proxymaxx-cli]` prefix. `serve --detach` returns a single status object
  instead and sends the stream to the session log.
- `flows` reads `session.ndjson`, which the engine host, this CLI or the app, appends to and
  never deletes. It works whether or not the CLI is the host, and it survives the engine
  stopping, so a session can be inspected after the fact. Unlike `serve`'s raw stdout, `flows`
  and `flows --follow` collapse the snapshots, so each flow is one line.
- Exit codes: `0` success, `1` error, `2` bad usage, `3` an engine is already running.
- `serve` starts a fresh session; the previous `session.ndjson` is replaced. Read what you need
  before starting another engine.
- `cert install` adds the local root CA to the user trust domain, with no admin prompt. Check
  `cert status` before expecting HTTPS flows to decrypt. The Android command does not need
  this: it installs the CA on the device, and root is obtained there, not on the Mac.
- `android prepare` leaves the engine running; `proxymaxx-cli stop` stops it when the
  session is over.
- The CLI never touches the macOS system proxy. Point clients at the port yourself, with
  `http_proxy`/`https_proxy`, an emulator, or the app's toggle.
- Rules are shared with the app. Editing `rules.json` by hand while the app owns the engine
  races the app's autosave; use the commands instead, and they apply live.
