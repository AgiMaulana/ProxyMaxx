package com.proxymaxx.vpn.vpn

import android.app.PendingIntent
import android.content.Intent
import android.graphics.drawable.Icon
import android.net.VpnService
import android.os.Build
import android.service.quicksettings.Tile
import android.service.quicksettings.TileService
import android.util.Log
import com.proxymaxx.vpn.MainActivity
import com.proxymaxx.vpn.R
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.collectLatest
import kotlinx.coroutines.launch

/**
 * Starts and stops the tunnel from the Quick Settings shade.
 *
 * The tile never keeps a state of its own. It renders [ProxyMaxxVpnService.isConnected], so a
 * tunnel started from the app, from the notification, or from this tile all read the same,
 * and one stopped by the system (consent revoked, tunnel revoked) flips the tile back too.
 *
 * The one thing a tile cannot do is grant VPN consent: that is a system dialog an activity
 * has to show. On the first tap, and only then, the app is opened to collect it.
 */
class ProxyMaxxVpnTileService : TileService() {

    private var listeningScope: CoroutineScope? = null

    override fun onTileAdded() {
        super.onTileAdded()
        render(ProxyMaxxVpnService.isConnected.value)
    }

    override fun onStartListening() {
        super.onStartListening()
        listeningScope?.cancel()
        val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
        listeningScope = scope
        scope.launch {
            ProxyMaxxVpnService.isConnected.collectLatest { connected -> render(connected) }
        }
    }

    override fun onStopListening() {
        listeningScope?.cancel()
        listeningScope = null
        super.onStopListening()
    }

    override fun onClick() {
        super.onClick()
        when {
            ProxyMaxxVpnService.isConnected.value -> disconnect()
            VpnService.prepare(this) == null -> connect()
            else -> openApp(autoStart = true)
        }
    }

    private fun render(connected: Boolean) {
        val tile = qsTile ?: return
        tile.state = if (connected) Tile.STATE_ACTIVE else Tile.STATE_INACTIVE
        tile.label = getString(R.string.tile_label)
        tile.icon = Icon.createWithResource(this, R.drawable.ic_tile_vpn)
        tile.subtitle = getString(
            if (connected) R.string.tile_state_connected else R.string.tile_state_disconnected,
        )
        tile.updateTile()
    }

    private fun connect() {
        val config = VpnConfigStore.load(this)
        try {
            startForegroundService(VpnConfig.startIntent(this, config))
        } catch (error: IllegalStateException) {
            // Android can refuse a foreground service started from the background. Opening
            // the app keeps the tile useful instead of leaving the tap with no effect; the
            // activity starts the tunnel once it is visible.
            Log.w(TAG, "could not start the tunnel from the tile: ${error.message}")
            openApp(autoStart = true)
        }
    }

    private fun disconnect() {
        startService(VpnConfig.stopIntent(this))
    }

    private fun openApp(autoStart: Boolean) {
        val intent = Intent(this, MainActivity::class.java).apply {
            addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_ACTIVITY_CLEAR_TOP)
            if (autoStart) putExtra(VpnConfig.EXTRA_AUTO_START, true)
        }
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            val pendingIntent = PendingIntent.getActivity(
                this,
                REQUEST_OPEN_APP,
                intent,
                PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
            )
            startActivityAndCollapse(pendingIntent)
        } else {
            @Suppress("DEPRECATION")
            startActivityAndCollapse(intent)
        }
    }

    private companion object {
        private const val TAG = "ProxyMaxxVpnTile"
        private const val REQUEST_OPEN_APP = 2
    }
}
