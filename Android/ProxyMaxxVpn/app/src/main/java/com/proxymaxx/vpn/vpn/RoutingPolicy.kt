package com.proxymaxx.vpn.vpn

import java.net.InetAddress

internal const val HTTP_PORT = 80
internal const val HTTPS_PORT = 443

/** QUIC runs here; denying it forces HTTPS back onto TCP, where it can be proxied. */
internal const val QUIC_PORT = 443

/**
 * Whether a packet is this device talking to itself, and so none of the tunnel's business.
 *
 * The tunnel advertises `0.0.0.0/0`, which also captures a client's connection to the device's
 * own `localhost`. Relaying it cannot work: the relay socket is dialled from the tunnel app's
 * side, and a socket's path is fixed by whoever dials it — so it reaches *that* side's
 * loopback, not the peer the client asked for, and the client sees `ECONNREFUSED`. A protected
 * socket did not fix that in practice. Android already holds a `local 127.0.0.0/8 … dev lo`
 * route, so the client's own connection completes on its own if it never enters the tun.
 *
 * `localhost` packets are therefore ignored rather than carried, which keeps every on-device
 * tool that drives an app over a local server working — Maestro's `maestro-app/driver` gRPC
 * server over `adb forward` is the one that prompted it — none of which has network traffic
 * worth showing in the proxy anyway.
 *
 * Both ends are checked: a loopback destination is the common case, but a packet *from*
 * loopback (a server answering, or a local proxy) must not be relayed either.
 */
internal fun isLoopbackTraffic(source: InetAddress, destination: InetAddress): Boolean =
    source.isLoopbackAddress || destination.isLoopbackAddress

/**
 * Whether this destination is carried by the proxy.
 *
 * When only HTTP is routed, everything else is dialled directly rather than refused: a phone
 * makes plenty of non-HTTP connections just to stay alive, and breaking those would make the
 * tunnel worse than useless.
 *
 * Loopback is not asked about here: [isLoopbackTraffic] answers it before this is consulted,
 * because it is about reaching the device at all rather than about the proxy.
 *
 * Kept apart from the router so the policy can be read and tested on its own, without the
 * tunnel or Android in the picture.
 */
internal fun tunnelsThroughProxy(config: VpnConfig, destinationPort: Int): Boolean = when {
    !config.proxyModeEnabled -> false
    !config.routeHttpOnly -> true
    else -> destinationPort == HTTP_PORT || destinationPort == HTTPS_PORT
}
