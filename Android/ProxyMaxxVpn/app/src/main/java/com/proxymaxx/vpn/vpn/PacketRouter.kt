package com.proxymaxx.vpn.vpn

import android.os.ParcelFileDescriptor
import android.util.Log
import java.io.Closeable
import java.io.FileInputStream
import java.io.FileOutputStream
import java.net.DatagramSocket
import java.net.InetAddress
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch

/**
 * Reads raw IP packets off the tunnel and puts them back.
 *
 * There is no netfilter here and no kernel help: every packet is parsed, matched to a flow,
 * carried by an ordinary socket, and its reply rebuilt by hand. That is the price of
 * capturing traffic from apps that ignore the system proxy — the reason this app exists.
 *
 * Only IPv4 is handled. The tunnel advertises a `0.0.0.0/0` route, and anything that is not
 * an IPv4 TCP or UDP datagram is dropped rather than guessed at.
 */
internal class PacketRouter(
    descriptor: ParcelFileDescriptor,
    private val config: VpnConfig,
    private val protectSocket: (Socket) -> Boolean,
    private val protectDatagram: (DatagramSocket) -> Boolean,
) : Closeable {
    private val input = FileInputStream(descriptor.fileDescriptor)
    private val output = FileOutputStream(descriptor.fileDescriptor)
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.IO)

    private val tcpConnections = ConcurrentHashMap<String, TcpConnection>()
    private val udpRelays = ConcurrentHashMap<String, UdpRelay>()

    private val writeLock = Any()
    private val running = AtomicBoolean(false)
    private var readJob: Job? = null

    fun start() {
        if (!running.compareAndSet(false, true)) return
        readJob = scope.launch { readLoop() }
    }

    override fun close() {
        if (!running.compareAndSet(true, false)) return
        readJob?.cancel()
        tcpConnections.values.forEach { it.close() }
        tcpConnections.clear()
        udpRelays.values.forEach { it.close() }
        udpRelays.clear()
        scope.cancel()
        try {
            input.close()
        } catch (_: Exception) {
        }
        try {
            output.close()
        } catch (_: Exception) {
        }
    }

    private fun readLoop() {
        val buffer = ByteArray(READ_BUFFER_SIZE)
        while (running.get()) {
            val length = try {
                input.read(buffer)
            } catch (error: Exception) {
                if (running.get()) Log.e(TAG, "tunnel read failed: ${error.message}")
                break
            }
            if (length <= 0) continue

            try {
                dispatch(buffer, length)
            } catch (error: Exception) {
                Log.e(TAG, "dropped malformed packet: ${error.message}")
            }
        }
    }

    private fun dispatch(packet: ByteArray, length: Int) {
        val header = Ipv4.header(packet, length) ?: return
        when (header.protocol) {
            Ipv4.PROTOCOL_TCP -> handleTcp(packet, header)
            Ipv4.PROTOCOL_UDP -> handleUdp(packet, header)
            else -> Unit
        }
    }

    private fun handleTcp(packet: ByteArray, header: Ipv4Header) {
        val segment = Ipv4.tcpSegment(packet, header) ?: return
        val key = flowKey(
            header.source, segment.sourcePort,
            header.destination, segment.destinationPort,
        )

        tcpConnections[key]?.let { connection ->
            connection.handle(segment)
            return
        }

        // Only a fresh handshake may open a flow; anything else is for a connection we
        // never had, so the client is told to give up rather than left waiting.
        if (!segment.isSyn || segment.isRst) {
            rejectTcp(header, segment)
            return
        }

        val connection = TcpConnection(
            config = config,
            clientAddress = header.source,
            clientPort = segment.sourcePort,
            serverAddress = header.destination,
            serverPort = segment.destinationPort,
            useProxy = tunnelsThroughProxy(config, segment.destinationPort),
            emit = ::emit,
            protect = protectSocket,
            scope = scope,
            onClosed = { closed -> tcpConnections.remove(closed.flowKey()) },
        )
        tcpConnections[key] = connection
        connection.handle(segment)
    }

    private fun handleUdp(packet: ByteArray, header: Ipv4Header) {
        val segment = Ipv4.udpSegment(packet, header) ?: return
        if (segment.destinationPort == QUIC_PORT) return
        if (segment.payload.isEmpty()) return

        val key = flowKey(
            header.source, segment.sourcePort,
            header.destination, segment.destinationPort,
        )
        val relay = udpRelays[key] ?: UdpRelay(
            clientAddress = header.source,
            clientPort = segment.sourcePort,
            serverAddress = header.destination,
            serverPort = segment.destinationPort,
            emit = ::emit,
            protect = protectDatagram,
            scope = scope,
            onClosed = { closed -> udpRelays.remove(closed.flowKey()) },
        ).also { udpRelays[key] = it }

        relay.send(segment.payload)
    }

    private fun rejectTcp(header: Ipv4Header, segment: TcpSegment) {
        emit(
            Ipv4.buildTcpPacket(
                source = header.destination,
                destination = header.source,
                sourcePort = segment.destinationPort,
                destinationPort = segment.sourcePort,
                sequence = segment.acknowledgement,
                acknowledgement = segment.sequence + 1,
                flags = Ipv4.TCP_FLAG_RST or Ipv4.TCP_FLAG_ACK,
            ),
        )
    }

    private fun emit(packet: ByteArray) {
        synchronized(writeLock) {
            try {
                output.write(packet)
                output.flush()
            } catch (error: Exception) {
                if (running.get()) Log.e(TAG, "tunnel write failed: ${error.message}")
            }
        }
    }

    private companion object {
        const val TAG = "PacketRouter"
        const val READ_BUFFER_SIZE = 32767
    }
}

internal fun flowKey(
    source: InetAddress,
    sourcePort: Int,
    destination: InetAddress,
    destinationPort: Int,
): String = "$source:$sourcePort->$destination:$destinationPort"

internal fun TcpConnection.flowKey(): String =
    flowKey(clientAddress, clientPort, serverAddress, serverPort)

internal fun UdpRelay.flowKey(): String =
    flowKey(clientAddress, clientPort, serverAddress, serverPort)
