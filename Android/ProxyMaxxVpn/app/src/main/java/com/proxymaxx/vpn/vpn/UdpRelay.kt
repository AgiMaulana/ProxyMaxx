package com.proxymaxx.vpn.vpn

import android.util.Log
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.InetSocketAddress
import java.nio.ByteBuffer
import java.nio.channels.DatagramChannel
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * Forwards one UDP flow.
 *
 * UDP goes straight to its destination rather than through the proxy. The proxy speaks
 * SOCKS5/TCP, and tunnelling datagrams through it would cost more than it buys: QUIC, mDNS
 * and friends are not what this tool is for. The socket is `protect()`ed so its own traffic
 * does not re-enter the tunnel.
 *
 * The one exception is destination port 443, which the router drops outright. QUIC lives
 * there, and letting it through would hand HTTPS to a path that is never inspected; denying
 * it makes the client fall back to TCP, where it *is* proxied.
 */
internal class UdpRelay(
    val clientAddress: InetAddress,
    val clientPort: Int,
    val serverAddress: InetAddress,
    val serverPort: Int,
    private val emit: (ByteArray) -> Unit,
    protect: (DatagramSocket) -> Boolean,
    scope: CoroutineScope,
    private val onClosed: (UdpRelay) -> Unit,
) {
    private val channel: DatagramChannel = DatagramChannel.open().apply {
        configureBlocking(true)
        protect(socket())
        bind(null)
        connect(InetSocketAddress(serverAddress, serverPort))
    }

    private val running = AtomicBoolean(true)

    init {
        scope.launch(Dispatchers.IO) { readResponses() }
    }

    fun send(payload: ByteArray) {
        if (!running.get()) return
        try {
            channel.write(ByteBuffer.wrap(payload))
        } catch (error: Exception) {
            Log.e(TAG, "UDP send to $serverAddress:$serverPort failed: ${error.message}")
            close()
        }
    }

    private fun readResponses() {
        val buffer = ByteBuffer.allocate(READ_BUFFER_SIZE)
        while (running.get()) {
            try {
                buffer.clear()
                val read = channel.read(buffer)
                if (read <= 0) continue
                val payload = ByteArray(read)
                buffer.flip()
                buffer.get(payload)
                emit(
                    Ipv4.buildUdpPacket(
                        source = serverAddress,
                        destination = clientAddress,
                        sourcePort = serverPort,
                        destinationPort = clientPort,
                        payload = payload,
                    ),
                )
            } catch (error: Exception) {
                if (running.get()) Log.e(TAG, "UDP receive failed: ${error.message}")
                break
            }
        }
        close()
    }

    fun close() {
        if (!running.compareAndSet(true, false)) return
        try {
            channel.close()
        } catch (_: Exception) {
        }
        onClosed(this)
    }

    private companion object {
        const val TAG = "UdpRelay"
        const val READ_BUFFER_SIZE = 65535
    }
}
