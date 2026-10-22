# ProxyMaxx VPN — the Android side

A small Android app that carries device traffic to the ProxyMaxx proxy. It exists
because the Android system proxy is advisory: it only reaches apps that choose to honour
`http_proxy`, and it says nothing at all about traffic that is not HTTP. Flutter, React
Native and most native HTTP stacks ignore it, which is exactly the traffic people most
often need to see.

A `VpnService` sees the packets themselves, so nothing can opt out.

## What it does

The app asks Android for a tunnel, then does the work a kernel would normally do:

```
app ──▶ tun ──▶ PacketRouter ──┬── TCP 80/443 ──▶ SOCKS5 ──▶ proxy ──▶ destination
                               ├── TCP other  ──────────────────────▶ destination
                               └── UDP        ──────────────────────▶ destination
```

- **TCP to 80/443** is carried by the proxy over **SOCKS5** — no authentication,
  `CONNECT` only.
- **Other TCP ports** are dialled directly, so the device keeps working normally.
- **UDP** is forwarded directly, except **destination port 443**, which is dropped so QUIC
  falls back to TCP where it can actually be inspected.
- **Nothing is decrypted on the device.** The tunnel is a pipe; the proxy is what decides
  whether a stream is decrypted.

### Host names, not just addresses

A tunnel only sees destination *addresses*, so a connection to `142.250.66.100:443` would
reach the proxy as a bare literal — useless for hostname rules and unreadable in the flow
list. So the proxy connection is deliberately **not** made on `SYN`. The handshake is
answered locally, the first payload is held back just long enough to look for a TLS
ClientHello, and the proxy is then dialled with the real host name from the SNI extension.
The buffer is flushed immediately afterwards, so nothing is delayed in practice.

Non-TLS traffic keeps its literal address and works the same way.

## Contract with the host app

The macOS app starts the tunnel with `am start`, so these extras are the interface:

| Extra | Type | Default | Meaning |
|---|---|---|---|
| `command` | string | `start` | `start` or `stop` |
| `proxy_host` | string | `10.0.2.2` | emulator alias for the host's loopback |
| `socks_port` | int | `8989` | the proxy's SOCKS5 listener |
| `http_port` | int | `9090` | the proxy's HTTP port |
| `route_http_only` | bool | `true` | proxy 80/443 only; everything else direct |
| `proxy_mode_enabled` | bool | `true` | `false` carries nothing to the proxy |
| `auto_start` | bool | `false` | connect as soon as the intent arrives |

```sh
adb shell am start -n com.proxymaxx.vpn/.MainActivity \
    --es proxy_host 10.0.2.2 --ei socks_port 8989 --ei http_port 9090
```

The app is also usable on its own — the launcher screen has the same four fields.

## Build

```sh
Scripts/build-android-vpn.sh            # debug APK → Resources/android/proxymaxx-vpn.apk
Scripts/build-android-vpn.sh release    # release APK
```

Needs a JDK (17+) and an Android SDK with platform 36. Android Studio provides both.

## Run it on an emulator

The tunnel needs something to talk to: **ProxyMaxx itself serves the SOCKS5 listener on
8989**, so start it first and leave it running. If 8989 was already taken — by ProxyMaxx, say
— the app re-selects a port and says so in its log; enter that port instead.

```sh
adb install -r Resources/android/proxymaxx-vpn.apk
adb shell am start -n com.proxymaxx.vpn/.MainActivity
```

On the emulator: leave **Proxy host** at `10.0.2.2` (the host machine as the emulator sees
it), leave **SOCKS5 port** at `8989`, then tap **Connect** and accept the system VPN prompt.
Android shows a persistent notification while the tunnel is up.

To point it at the host from the command line instead, with the proxy details attached:

```sh
adb shell am start -n com.proxymaxx.vpn/.MainActivity \
    --es proxy_host 10.0.2.2 --ei socks_port 8989 --ei http_port 9090 --ez auto_start true
```

The proxy's certificate must also be trusted **inside the emulator** for HTTPS to be
readable, otherwise the tunnel carries the traffic but every TLS handshake fails. That is the
emulator system-store step, not something this app does.

## Limits, stated plainly

- **IPv4 only.** The tunnel advertises a `0.0.0.0/0` route, and IPv6 traffic is dropped
  rather than guessed at.
- **No on-device TLS interception.** Certificate work happens in the emulator's system store
  and on the host, never here.
- **UDP is not proxied.** Only the `443` drop is deliberate; the rest is straight through.
- **TCP is relayed, not terminated.** The sequence numbers are invented for the client side
  and the relay assumes in-order delivery, which is what a local tunnel sees. It is not a
  general-purpose TCP stack.
- **HTTP/2 and HTTP/3 are not parsed here.** The tunnel never looks above the transport
  layer, so anything a client chooses to speak is carried unchanged.
