package com.proxymaxx.vpn.vpn

internal const val HTTP_PORT = 80
internal const val HTTPS_PORT = 443

/** QUIC runs here; denying it forces HTTPS back onto TCP, where it can be proxied. */
internal const val QUIC_PORT = 443

/**
 * Whether this destination is carried by the proxy.
 *
 * When only HTTP is routed, everything else is dialled directly rather than refused: a phone
 * makes plenty of non-HTTP connections just to stay alive, and breaking those would make the
 * tunnel worse than useless.
 *
 * Kept apart from the router so the policy can be read and tested on its own, without the
 * tunnel or Android in the picture.
 */
internal fun tunnelsThroughProxy(config: VpnConfig, destinationPort: Int): Boolean = when {
    !config.proxyModeEnabled -> false
    !config.routeHttpOnly -> true
    else -> destinationPort == HTTP_PORT || destinationPort == HTTPS_PORT
}
