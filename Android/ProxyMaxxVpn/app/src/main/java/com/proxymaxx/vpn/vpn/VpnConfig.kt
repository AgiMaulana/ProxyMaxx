package com.proxymaxx.vpn.vpn

import android.content.Context
import android.content.Intent

/**
 * What the host app tells the tunnel to do.
 *
 * The extras here are the contract ProxyMaxx uses when it launches the tunnel:
 *
 * ```
 * adb shell am start -n com.proxymaxx.vpn/.MainActivity \
 *     --es proxy_host 10.0.2.2 --ei socks_port 8989 --ei http_port 9090
 * ```
 *
 * `10.0.2.2` is the Android emulator's alias for the host machine's loopback, which is where
 * the proxy listens.
 */
data class VpnConfig(
    val proxyHost: String = DEFAULT_PROXY_HOST,
    val socksPort: Int = DEFAULT_SOCKS_PORT,
    val httpPort: Int = DEFAULT_HTTP_PORT,
    /** When true only TCP to 80/443 is proxied; other ports go direct. */
    val routeHttpOnly: Boolean = true,
    /** When false the tunnel carries no traffic to the proxy at all. */
    val proxyModeEnabled: Boolean = true,
) {
    companion object {
        const val DEFAULT_PROXY_HOST = "10.0.2.2"
        const val DEFAULT_SOCKS_PORT = 8989
        const val DEFAULT_HTTP_PORT = 9090

        const val EXTRA_COMMAND = "command"
        const val EXTRA_PROXY_HOST = "proxy_host"
        const val EXTRA_SOCKS_PORT = "socks_port"
        const val EXTRA_HTTP_PORT = "http_port"
        const val EXTRA_ROUTE_HTTP_ONLY = "route_http_only"
        const val EXTRA_PROXY_MODE_ENABLED = "proxy_mode_enabled"
        const val EXTRA_AUTO_START = "auto_start"

        const val COMMAND_START = "start"
        const val COMMAND_STOP = "stop"

        fun fromIntent(intent: Intent?): VpnConfig {
            if (intent == null) return VpnConfig()
            return VpnConfig(
                proxyHost = intent.getStringExtra(EXTRA_PROXY_HOST) ?: DEFAULT_PROXY_HOST,
                socksPort = intent.getIntExtra(EXTRA_SOCKS_PORT, DEFAULT_SOCKS_PORT),
                httpPort = intent.getIntExtra(EXTRA_HTTP_PORT, DEFAULT_HTTP_PORT),
                routeHttpOnly = intent.getBooleanExtra(EXTRA_ROUTE_HTTP_ONLY, true),
                proxyModeEnabled = intent.getBooleanExtra(EXTRA_PROXY_MODE_ENABLED, true),
            )
        }

        /**
         * True when the intent carries proxy settings of its own.
         *
         * An intent with only [EXTRA_AUTO_START] or [EXTRA_COMMAND] says what to do, not where
         * to send traffic, so the stored settings are the better answer for it.
         */
        fun hasConfigExtras(intent: Intent?): Boolean {
            if (intent == null) return false
            return intent.hasExtra(EXTRA_PROXY_HOST) ||
                intent.hasExtra(EXTRA_SOCKS_PORT) ||
                intent.hasExtra(EXTRA_HTTP_PORT) ||
                intent.hasExtra(EXTRA_ROUTE_HTTP_ONLY) ||
                intent.hasExtra(EXTRA_PROXY_MODE_ENABLED)
        }

        fun startIntent(context: Context, config: VpnConfig): Intent =
            Intent(context, ProxyMaxxVpnService::class.java).apply {
                putExtra(EXTRA_COMMAND, COMMAND_START)
                putExtra(EXTRA_PROXY_HOST, config.proxyHost)
                putExtra(EXTRA_SOCKS_PORT, config.socksPort)
                putExtra(EXTRA_HTTP_PORT, config.httpPort)
                putExtra(EXTRA_ROUTE_HTTP_ONLY, config.routeHttpOnly)
                putExtra(EXTRA_PROXY_MODE_ENABLED, config.proxyModeEnabled)
            }

        fun stopIntent(context: Context): Intent =
            Intent(context, ProxyMaxxVpnService::class.java).apply {
                putExtra(EXTRA_COMMAND, COMMAND_STOP)
            }
    }
}
