package com.proxymaxx.vpn.vpn

import android.app.Notification
import android.app.NotificationChannel
import android.app.NotificationManager
import android.app.PendingIntent
import android.content.Intent
import android.content.pm.PackageManager
import android.content.pm.ServiceInfo
import android.graphics.drawable.Icon
import android.net.ConnectivityManager
import android.net.IpPrefix
import android.net.VpnService
import android.os.Build
import android.os.ParcelFileDescriptor
import android.util.Log
import com.proxymaxx.vpn.MainActivity
import com.proxymaxx.vpn.R
import kotlinx.coroutines.flow.MutableStateFlow
import kotlinx.coroutines.flow.StateFlow
import kotlinx.coroutines.flow.asStateFlow
import java.net.DatagramSocket
import java.net.Inet4Address
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.atomic.AtomicBoolean

/**
 * Carries device traffic to the proxy.
 *
 * A `VpnService` is used because the system proxy only reaches apps that ask for it: Flutter,
 * React Native and most native HTTP stacks happily ignore `http_proxy`, and anything that is
 * not HTTP at all ignores it by definition. A tunnel sees the packets themselves.
 *
 * A private range address is used deliberately — `addDisallowedApplication` keeps this app's
 * own sockets out of its own tunnel, which would otherwise be a loop.
 */
class ProxyMaxxVpnService : VpnService() {

    private var descriptor: ParcelFileDescriptor? = null
    private var router: PacketRouter? = null
    private val running = AtomicBoolean(false)

    override fun onCreate() {
        super.onCreate()
        createNotificationChannel()
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int {
        val command = intent?.getStringExtra(VpnConfig.EXTRA_COMMAND)
        if (command == VpnConfig.COMMAND_STOP) {
            stopTunnel()
            return START_NOT_STICKY
        }
        startTunnel(VpnConfig.fromIntent(intent))
        return START_STICKY
    }

    override fun onRevoke() {
        super.onRevoke()
        stopTunnel()
    }

    override fun onDestroy() {
        stopTunnel()
        super.onDestroy()
    }

    /**
     * The resolvers of the network underneath, read before this tunnel exists.
     *
     * It has to be read first: once the tunnel is up it *is* the default network, so asking
     * then would return this tunnel's own — deliberately empty — DNS configuration.
     */
    private fun resolverAddresses(): List<InetAddress> {
        // excludeRoute arrived in API 33. Below that the tunnel still works; name lookups
        // simply take their chances with the underlying resolver, as they did before.
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.TIRAMISU) return emptyList()
        val manager = getSystemService(ConnectivityManager::class.java) ?: return emptyList()
        val network = manager.activeNetwork ?: return emptyList()
        return manager.getLinkProperties(network)?.dnsServers.orEmpty()
    }

    private fun startTunnel(config: VpnConfig) {
        if (running.get()) {
            Log.d(TAG, "tunnel is already running")
            return
        }

        // Go foreground before touching netd. A started foreground service is killed if it
        // has not called startForeground() within a few seconds, and establishing the tunnel
        // is a round trip through the system — long enough to miss that deadline on a cold
        // process, which the platform reports as ForegroundServiceDidNotStartInTime.
        startForegroundNotification(config)

        val established = try {
            Builder()
                .setSession(SESSION_NAME)
                .setMtu(Ipv4.MTU)
                .addAddress(TUN_ADDRESS, TUN_PREFIX_LENGTH)
                .addRoute("0.0.0.0", 0)
                .apply {
                    // Resolution is handed to the network underneath, and its resolvers are
                    // routed around this tunnel rather than through it. Both halves are
                    // needed: without declaring them the VPN network has no resolver at all,
                    // and without excluding them the lookup enters the tunnel, where the UDP
                    // relay cannot answer it. The result of getting this wrong is a device
                    // that reports no internet at all.
                    resolverAddresses().forEach { resolver ->
                        addDnsServer(resolver)
                        excludeRoute(IpPrefix(resolver, if (resolver is Inet4Address) 32 else 128))
                    }
                }
                .setBlocking(true)
                .apply {
                    // Without this the tunnel would capture its own proxy connections.
                    try {
                        addDisallowedApplication(packageName)
                    } catch (error: PackageManager.NameNotFoundException) {
                        Log.w(TAG, "could not exclude own package from the tunnel: ${error.message}")
                    }
                }
                .establish()
        } catch (error: Exception) {
            Log.e(TAG, "could not establish the tunnel: ${error.message}")
            null
        }

        if (established == null) {
            Log.e(TAG, "tunnel permission was refused")
            stopSelf()
            return
        }

        descriptor = established
        router = PacketRouter(established, config, ::protectSocket, ::protectDatagram)
            .also { it.start() }
        running.set(true)
        connected.value = true
        Log.d(TAG, "tunnel established, proxying ${config.proxyHost}:${config.socksPort}")
    }

    private fun stopTunnel() {
        router?.close()
        router = null
        try {
            descriptor?.close()
        } catch (_: Exception) {
        }
        descriptor = null
        running.set(false)
        connected.value = false
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            stopForeground(STOP_FOREGROUND_REMOVE)
        }
        stopSelf()
    }

    /** Keeps this app's own sockets out of the tunnel, which would otherwise loop. */
    private fun protectSocket(socket: Socket): Boolean = protect(socket)

    private fun protectDatagram(socket: DatagramSocket): Boolean = protect(socket)

    private fun createNotificationChannel() {
        val manager = getSystemService(NotificationManager::class.java) ?: return
        val channel = NotificationChannel(
            CHANNEL_ID,
            "ProxyMaxx VPN",
            NotificationManager.IMPORTANCE_LOW,
        ).apply {
            description = "Shows while the traffic-capture tunnel is running"
            setShowBadge(false)
        }
        manager.createNotificationChannel(channel)
    }

    private fun startForegroundNotification(config: VpnConfig) {
        val open = PendingIntent.getActivity(
            this,
            0,
            Intent(this, MainActivity::class.java),
            PendingIntent.FLAG_IMMUTABLE,
        )
        // Disconnecting from the shade means the user does not have to open the app, so the
        // action carries the same command the in-app button sends.
        val disconnect = PendingIntent.getService(
            this,
            1,
            Intent(this, ProxyMaxxVpnService::class.java).apply {
                putExtra(VpnConfig.EXTRA_COMMAND, VpnConfig.COMMAND_STOP)
            },
            PendingIntent.FLAG_IMMUTABLE or PendingIntent.FLAG_UPDATE_CURRENT,
        )
        val text = if (config.proxyModeEnabled) {
            "Sending traffic to ${config.proxyHost}:${config.socksPort}"
        } else {
            "Proxy bypassed — passing traffic through untouched"
        }
        val notification: Notification = Notification.Builder(this, CHANNEL_ID)
            .setContentTitle("ProxyMaxx VPN")
            .setContentText(text)
            .setSmallIcon(android.R.drawable.ic_lock_lock)
            .setContentIntent(open)
            .setOngoing(true)
            .addAction(
                Notification.Action.Builder(
                    Icon.createWithResource(this, R.drawable.ic_notification_disconnect),
                    "Disconnect",
                    disconnect,
                ).build(),
            )
            .build()

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.UPSIDE_DOWN_CAKE) {
            startForeground(
                NOTIFICATION_ID,
                notification,
                ServiceInfo.FOREGROUND_SERVICE_TYPE_SPECIAL_USE,
            )
        } else {
            startForeground(NOTIFICATION_ID, notification)
        }
    }

    companion object {
        private const val TAG = "ProxyMaxxVpnService"
        private const val CHANNEL_ID = "proxymaxx_vpn"
        private const val NOTIFICATION_ID = 1
        private const val SESSION_NAME = "ProxyMaxx VPN"
        private const val TUN_ADDRESS = "10.255.0.1"
        private const val TUN_PREFIX_LENGTH = 32

        private val connected = MutableStateFlow(false)

        /** True while the tunnel is up, so the UI can reflect the real service state. */
        val isConnected: StateFlow<Boolean> = connected.asStateFlow()
    }
}
