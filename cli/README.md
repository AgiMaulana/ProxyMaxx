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
proxymaxx-cli export --output PATH [--mode all|enabledRules]
proxymaxx-cli import --input  PATH [--mode append|override]
```

Short options (`-o`, `-i`, `-m`) work alongside the long ones.

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
  `cert status` before expecting HTTPS flows to decrypt.
- The CLI never touches the macOS system proxy. Point clients at the port yourself, with
  `http_proxy`/`https_proxy`, an emulator, or the app's toggle.
- Rules are shared with the app. Editing `rules.json` by hand while the app owns the engine
  races the app's autosave; use the commands instead, and they apply live.
