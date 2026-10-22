package com.proxymaxx.vpn.vpn

import android.util.Log
import java.io.ByteArrayOutputStream
import java.net.InetAddress
import java.net.InetSocketAddress
import java.net.Socket
import java.nio.ByteBuffer
import java.nio.channels.SocketChannel
import java.util.concurrent.ConcurrentLinkedQueue
import java.util.concurrent.atomic.AtomicBoolean
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch

/**
 * One proxied TCP connection, now speaking raw IP on one side and SOCKS5 on the other.
 *
 * The subtle part is *when* to dial the proxy. Connecting on SYN would commit us to the
 * literal address from the IP header, throwing away the host name — and with it every
 * hostname rule and any chance of a readable flow list. So the handshake is answered
 * locally straight away, the first payload is held back just long enough to look for a TLS
 * ClientHello, and only then is the proxy connection opened with the real host.
 *
 * Traffic that is not TLS keeps its literal address and works exactly the same way.
 */
internal class TcpConnection(
    private val config: VpnConfig,
    val clientAddress: InetAddress,
    val clientPort: Int,
    val serverAddress: InetAddress,
    val serverPort: Int,
    /** False carries this connection straight to its destination, bypassing the proxy. */
    private val useProxy: Boolean,
    private val emit: (ByteArray) -> Unit,
    private val protect: (Socket) -> Boolean,
    private val scope: CoroutineScope,
    private val onClosed: (TcpConnection) -> Unit,
) {
    /** Sequence number we invent for the server side; the peer only ever echoes it. */
    private var serverSequence = INITIAL_SERVER_SEQUENCE

    /** How far the client's byte stream has been forwarded, and what of a segment is new. */
    private val inbound = InboundStream()

    private var host = serverAddress.hostAddress ?: ""

    private val writeLock = Any()
    private val pending = ConcurrentLinkedQueue<ByteArray>()
    private val connecting = AtomicBoolean(false)
    private val closed = AtomicBoolean(false)

    @Volatile private var socket: SocketChannel? = null
    @Volatile private var synAcknowledged = false

    /** True once the destination host was recovered from a TLS ClientHello. */
    @Volatile var resolvedHost: String? = null
        private set

    fun handle(segment: TcpSegment) {
        if (closed.get()) return
        if (segment.isRst) {
            Log.d(TAG, "client reset $host:$serverPort")
            close()
            return
        }

        Log.v(
            TAG,
            "segment $host:$serverPort flags=${segment.flags} seq=${segment.sequence} " +
                "ack=${segment.acknowledgement} payload=${segment.payload.size}",
        )

        if (segment.isSyn && !synAcknowledged) {
            Log.d(TAG, "SYN received for $serverAddress:$serverPort")
            inbound.open(segment.sequence)
            synAcknowledged = true
            emit(
                Ipv4.buildTcpPacket(
                    source = serverAddress,
                    destination = clientAddress,
                    sourcePort = serverPort,
                    destinationPort = clientPort,
                    sequence = serverSequence,
                    acknowledgement = inbound.next,
                    flags = Ipv4.TCP_FLAG_SYN or Ipv4.TCP_FLAG_ACK,
                    options = Ipv4.mssOption(),
                ),
            )
            // A SYN consumes one sequence number, so the first byte we ever send has to be
            // the next one. Leaving this at the SYN's number makes the peer treat our first
            // byte as an overlap with the handshake and trim it — the stream then starts one
            // byte late and TLS rejects the record it sees.
            serverSequence += 1
            Log.d(TAG, "sent SYN-ACK for $serverAddress:$serverPort")
        }

        val payload = segment.payload
        if (payload.isNotEmpty()) {
            val fresh = inbound.accept(segment.sequence, payload)
            if (fresh == null) {
                Log.d(TAG, "ignored ${payload.size} bytes at ${segment.sequence} for $host:$serverPort")
            } else {
                Log.v(TAG, "forwarding ${fresh.size} bytes for $host:$serverPort")
                synchronized(writeLock) {
                    val channel = socket
                    if (channel != null) {
                        writeToProxy(channel, fresh)
                    } else {
                        pending.add(fresh)
                        if (targetReady()) startConnecting()
                    }
                }
            }
            acknowledgeClient()
        }

        if (segment.isFin) close()
    }

    /**
     * Acknowledge the client's payload on its own, without waiting for a reply to carry it.
     *
     * The proxy side can take a certificate to mint before it answers anything, so an
     * acknowledgement that only rides along with the first server byte arrives too late to
     * stop the retransmission [InboundStream] then has to trim. One empty segment is cheap.
     */
    private fun acknowledgeClient() {
        if (!synAcknowledged) return
        emit(
            Ipv4.buildTcpPacket(
                source = serverAddress,
                destination = clientAddress,
                sourcePort = serverPort,
                destinationPort = clientPort,
                sequence = serverSequence,
                acknowledgement = inbound.next,
                flags = Ipv4.TCP_FLAG_ACK,
            ),
        )
    }

    /**
     * True once enough of the first payload has arrived to name the destination.
     *
     * The name lives at the *end* of a TLS ClientHello and the record arrives split across
     * several TCP segments, so dialling on the first one would lose it and send the proxy a
     * bare literal instead. The proxy connection is therefore held back until the whole
     * first record is present; the client sends it immediately, so nothing waits on a peer.
     *
     * Anything that is not a TLS handshake is dialled on the first payload exactly as before.
     */
    private fun targetReady(): Boolean {
        if (!useProxy) return true
        val head = pending.peek() ?: return false
        if (head.isEmpty()) return false
        if (head[0].toInt() and 0xFF != TLS_HANDSHAKE_RECORD) return true
        val buffered = pendingBytes()
        val recordLength = TlsClientHello.firstRecordLength(buffered) ?: return false
        // A record longer than the TLS maximum is not a hello worth waiting for.
        if (recordLength > MAX_TLS_RECORD) return true
        return buffered.size >= recordLength
    }

    /** Everything queued for the proxy, concatenated so a split record can be read whole. */
    private fun pendingBytes(): ByteArray {
        val combined = ByteArrayOutputStream()
        for (chunk in pending) combined.write(chunk)
        return combined.toByteArray()
    }

    private fun resolveHostFrom(record: ByteArray) {
        val name = TlsClientHello.serverName(record) ?: return
        if (name.isNotEmpty()) {
            host = name
            resolvedHost = name
            Log.d(TAG, "resolved $serverAddress:$serverPort to $name")
        }
    }

    private fun startConnecting() {
        if (!connecting.compareAndSet(false, true)) return
        scope.launch(Dispatchers.IO) {
            try {
                // The name has to be known before the SOCKS request goes out, but the hello
                // that carries it may still have been arriving while this coroutine started.
                if (useProxy) {
                    synchronized(writeLock) { resolveHostFrom(pendingBytes()) }
                }
                val channel = SocketChannel.open()
                channel.configureBlocking(true)
                protect(channel.socket())
                if (useProxy) {
                    channel.connect(InetSocketAddress(config.proxyHost, config.socksPort))
                    Socks5.connect(channel, host, serverPort)
                } else {
                    channel.connect(InetSocketAddress(serverAddress, serverPort))
                }
                synchronized(writeLock) {
                    socket = channel
                    var buffered = pending.poll()
                    while (buffered != null) {
                        writeToProxy(channel, buffered)
                        buffered = pending.poll()
                    }
                }
                Log.d(
                    TAG,
                    if (useProxy) "established $host:$serverPort through the proxy"
                    else "established $host:$serverPort directly",
                )
                readFromProxy(channel)
            } catch (error: Exception) {
                // Closing the channel from another thread surfaces here as an exception that
                // carries no message at all. Logging that as a failure makes every page that
                // finishes loading look like it broke.
                if (closed.get()) {
                    Log.d(TAG, "connection to $host:$serverPort closed")
                } else {
                    Log.e(TAG, "proxy connection to $host:$serverPort failed: ${error.message}")
                    abort()
                }
            } finally {
                close()
            }
        }
    }

    private fun readFromProxy(channel: SocketChannel) {
        val buffer = ByteBuffer.allocate(READ_BUFFER_SIZE)
        while (!closed.get()) {
            buffer.clear()
            val read = channel.read(buffer)
            if (read < 0) break
            if (read == 0) continue
            Log.v(TAG, "received $read bytes from proxy for $host:$serverPort")
            val data = ByteArray(read)
            buffer.flip()
            buffer.get(data)
            emitToClient(data)
        }
    }

    /**
     * Put one read back on the tun as one packet per MTU.
     *
     * A single read can return far more than fits in a packet — a TLS flight or a response
     * body routinely does — and the kernel refuses a tun write larger than the interface's
     * MTU. Splitting here is what keeps a whole TLS handshake from being dropped on the way
     * back, which is silent: the peer simply never sees the flight and the handshake stalls.
     */
    private fun emitToClient(data: ByteArray) {
        for (chunk in Ipv4.tcpPayloadChunks(data)) {
            emit(
                Ipv4.buildTcpPacket(
                    source = serverAddress,
                    destination = clientAddress,
                    sourcePort = serverPort,
                    destinationPort = clientPort,
                    sequence = serverSequence,
                    acknowledgement = inbound.next,
                    flags = Ipv4.TCP_FLAG_PSH or Ipv4.TCP_FLAG_ACK,
                    payload = chunk,
                ),
            )
            serverSequence += chunk.size
        }
    }

    private fun writeToProxy(channel: SocketChannel, payload: ByteArray) {
        try {
            val buffer = ByteBuffer.wrap(payload)
            while (buffer.hasRemaining()) channel.write(buffer)
        } catch (error: Exception) {
            Log.e(TAG, "write to proxy failed for $host:$serverPort: ${error.message}")
            abort()
        }
    }

    private fun abort() {
        if (closed.compareAndSet(false, true)) {
            Log.w(TAG, "aborting $host:$serverPort")
            emit(
                Ipv4.buildTcpPacket(
                    source = serverAddress,
                    destination = clientAddress,
                    sourcePort = serverPort,
                    destinationPort = clientPort,
                    sequence = serverSequence,
                    acknowledgement = inbound.next,
                    flags = Ipv4.TCP_FLAG_RST or Ipv4.TCP_FLAG_ACK,
                ),
            )
            closeSocket()
            onClosed(this)
        }
    }

    fun close() {
        if (closed.compareAndSet(false, true)) {
            Log.d(TAG, "closed $host:$serverPort")
            if (synAcknowledged) {
                emit(
                    Ipv4.buildTcpPacket(
                        source = serverAddress,
                        destination = clientAddress,
                        sourcePort = serverPort,
                        destinationPort = clientPort,
                        sequence = serverSequence,
                        acknowledgement = inbound.next,
                        flags = Ipv4.TCP_FLAG_FIN or Ipv4.TCP_FLAG_ACK,
                    ),
                )
                serverSequence += 1
            }
            closeSocket()
            onClosed(this)
        }
    }

    private fun closeSocket() {
        try {
            socket?.close()
        } catch (_: Exception) {
        }
        socket = null
        pending.clear()
    }

    private companion object {
        const val TAG = "TcpConnection"
        const val INITIAL_SERVER_SEQUENCE = 1000L
        const val READ_BUFFER_SIZE = 16384

        /** First byte of a TLS record carrying a handshake, which is how a hello announces itself. */
        const val TLS_HANDSHAKE_RECORD = 0x16
        /** The most a TLS record may declare; past this it is not a hello worth waiting for. */
        const val MAX_TLS_RECORD = 16384
    }
}
