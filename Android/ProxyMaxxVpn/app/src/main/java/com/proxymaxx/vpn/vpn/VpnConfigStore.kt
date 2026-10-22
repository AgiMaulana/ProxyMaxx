package com.proxymaxx.vpn.vpn

import android.content.Context

/**
 * Keeps the last proxy settings on disk.
 *
 * The Quick Settings tile can start the tunnel while the app has not run in this process, so
 * the settings cannot live in the activity alone. Whatever the app last connected with is
 * what the tile connects with next.
 */
object VpnConfigStore {

    private const val FILE_NAME = "vpn_config"
    private const val KEY_PROXY_HOST = "proxy_host"
    private const val KEY_SOCKS_PORT = "socks_port"
    private const val KEY_HTTP_PORT = "http_port"
    private const val KEY_ROUTE_HTTP_ONLY = "route_http_only"
    private const val KEY_PROXY_MODE_ENABLED = "proxy_mode_enabled"

    fun load(context: Context): VpnConfig {
        val preferences = preferences(context)
        return VpnConfig(
            proxyHost = preferences.getString(KEY_PROXY_HOST, VpnConfig.DEFAULT_PROXY_HOST)
                ?: VpnConfig.DEFAULT_PROXY_HOST,
            socksPort = preferences.getInt(KEY_SOCKS_PORT, VpnConfig.DEFAULT_SOCKS_PORT),
            httpPort = preferences.getInt(KEY_HTTP_PORT, VpnConfig.DEFAULT_HTTP_PORT),
            routeHttpOnly = preferences.getBoolean(KEY_ROUTE_HTTP_ONLY, true),
            proxyModeEnabled = preferences.getBoolean(KEY_PROXY_MODE_ENABLED, true),
        )
    }

    fun save(context: Context, config: VpnConfig) {
        preferences(context).edit()
            .putString(KEY_PROXY_HOST, config.proxyHost)
            .putInt(KEY_SOCKS_PORT, config.socksPort)
            .putInt(KEY_HTTP_PORT, config.httpPort)
            .putBoolean(KEY_ROUTE_HTTP_ONLY, config.routeHttpOnly)
            .putBoolean(KEY_PROXY_MODE_ENABLED, config.proxyModeEnabled)
            .apply()
    }

    private fun preferences(context: Context) = context.applicationContext
        .getSharedPreferences(FILE_NAME, Context.MODE_PRIVATE)
}
