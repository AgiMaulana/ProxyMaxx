# How the Mac app and the Android VPN app talk

The link is deliberately tiny. There is **no socket between the two apps, no handshake, and no
protocol of their own** — the Mac app configures the tunnel once through an Android intent, and
after that the tunnel uses SOCKS5, which the Mac app already speaks. Everything the tunnel
carries arrives at the Mac as an ordinary SOCKS5 connection to the same port any other client
would use.

## The two directions

```
Mac app                                            Android VPN app
   │                                                        │
   │  1. adb shell am start -n <pkg>/<Activity>             │
   │       --es proxy_host 10.0.2.2                         │
   │       --ei socks_port 8989                             │
   │       --ei http_port  9090                             │
   │       --ez auto_start true                             │
   ├───────────────────────────────────────────────────────►│  (config, once)
   │                                                        │
   │  2. SOCKS5 CONNECT host:port                           │
   │◄───────────────────────────────────────────────────────┤  (per connection)
   │                                                        │
   │  3. whatever the client speaks — TLS, HTTP             │
   │◄───────────────────────────────────────────────────────┤
```

Step 1 is configuration only. Steps 2 and 3 are the whole runtime relationship, and the Mac app
cannot tell the tunnel apart from `curl --socks5-hostname`.

## Step 1 — the configuration contract

The configuration extras understood by `ProxyMaxxVpnService.onStartCommand`:

| Extra | Type | Default | Meaning |
|---|---|---|---|
| `command` | String | — | `start`, or `stop`. Absent or null is treated as `start`. |
| `proxy_host` | String | `10.0.2.2` | Where the Mac app listens, as seen from the device. |
| `socks_port` | int | `8989` | The SOCKS5 listener to send traffic to. |
| `http_port` | int | `9090` | The HTTP listener. Informational for the tunnel. |
| `route_http_only` | boolean | `true` | Only TCP 80/443 go to the proxy; other ports are dialled directly. |
| `proxy_mode_enabled` | boolean | `true` | When false, the tunnel carries nothing. |
| `auto_start` | boolean | `false` | Read by the UI: connect as soon as the app opens. |

The UI reads the same names in the opposite direction: it takes the values out of the launch
intent, then puts them back on the service intent together with `command=start` and
`proxy_mode_enabled`.

The Mac app's one-click script launches the activity with the three config extras and
`auto_start`, and no `command`: the app opens already configured and connects itself, leaving
only Android's own consent prompt to accept.

## Step 2 — the SOCKS5 client

The tunnel's packet router applies these rules:

- A TCP flow for a destination the policy sends to the proxy is reassembled from the tun, then
  dialled through SOCKS5 at `proxy_host:socks_port`.
- The destination is sent **as a domain name** where the packet carried one, so the Mac app
  resolves it, not the device.
- The outbound socket is `protect()`ed and the app excludes itself with
  `addDisallowedApplication`, so the tunnel never captures its own traffic.
- TLS host names are recovered from the ClientHello for flow naming — the tunnel does **not**
  decrypt anything.

## Step 3 — what the tunnel does with each protocol

| Traffic | Behaviour |
|---|---|
| TCP 80/443 | Reassembled, tunnelled to the Mac over SOCKS5. |
| Other TCP | Dialled directly, so the device keeps working when the proxy is not the point. |
| UDP | Dialled directly, per flow, and **not** proxied — the Mac's SOCKS listener is TCP-only. |
| UDP 443 (QUIC) | Dropped, so HTTP/3 falls back to TCP where it can be inspected. |
| UDP 53 (DNS) | Depends on the VPN's DNS configuration — see the note below. |

## The tun interface

Identical on both sides: address `10.255.0.1/32`, MTU `1500`, route `0.0.0.0/0`, blocking mode,
and the app excluded from its own tunnel.

## Design notes

Two decisions are worth recording, both found by running the tunnel:

- **DNS.** Pointing the VPN at `8.8.8.8` and relying on the tunnel's own UDP relay looks
  clean, but that relay is a protected socket and cannot get a route out in every
  environment. When it cannot, every lookup fails and the device reports no internet at
  all. The tunnel declares the resolvers of the *underlying* network instead and excludes
  their addresses from the tun, so resolution never depends on a relay that is not meant
  to carry it.
- **Going foreground.** A started foreground service is killed if it has not called
  `startForeground()` within a few seconds, and `establish()` is a round trip through netd.
  Calling `startForeground()` afterwards is survivable when a person taps a button, but not
  when the service is started for you — so the tunnel goes foreground first.

`auto_start` makes an install end in a connection rather than a tap, and the one-click
script sets it.
