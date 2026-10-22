package com.proxymaxx.vpn.vpn

import java.nio.ByteBuffer
import java.nio.channels.SocketChannel

/**
 * Minimal SOCKS5 client: no authentication, CONNECT only.
 *
 * Both ProxyMaxx and ProxyMaxx expose a SOCKS5 listener, and it is the only way the tunnel
 * hands TCP to the proxy. There is deliberately no HTTP CONNECT path: for arbitrary
 * non-HTTP destinations CONNECT would be a lie, and every byte on the wire here is opaque
 * to the tunnel anyway — the proxy is what decides whether the stream is decrypted.
 */
internal object Socks5 {
    private const val VERSION = 0x05
    private const val METHOD_NO_AUTH = 0x00
    private const val COMMAND_CONNECT = 0x01
    private const val RESERVED = 0x00
    private const val ADDRESS_IPV4 = 0x01
    private const val ADDRESS_DOMAIN = 0x03
    private const val REPLY_SUCCEEDED = 0x00

    private val replyErrors = mapOf(
        1 to "general SOCKS server failure",
        2 to "connection not allowed by ruleset",
        3 to "network unreachable",
        4 to "host unreachable",
        5 to "connection refused",
        6 to "TTL expired",
        7 to "command not supported",
        8 to "address type not supported",
    )

    fun connect(channel: SocketChannel, host: String, port: Int) {
        channel.write(ByteBuffer.wrap(byteArrayOf(VERSION.toByte(), 1, METHOD_NO_AUTH.toByte())))

        val greeting = readFully(channel, 2)
        val version = greeting[0].toInt() and 0xFF
        val method = greeting[1].toInt() and 0xFF
        if (version != VERSION) throw Socks5Exception("proxy is not SOCKS5 (version $version)")
        if (method != METHOD_NO_AUTH) throw Socks5Exception("proxy demands authentication (method $method)")

        val address = encodeAddress(host)
        // VER + CMD + RSV, then the address (which already carries its ATYP byte), then the port.
        val request = ByteArray(3 + address.size + 2)
        request[0] = VERSION.toByte()
        request[1] = COMMAND_CONNECT.toByte()
        request[2] = RESERVED.toByte()
        request[3] = address[0]
        System.arraycopy(address, 1, request, 4, address.size - 1)
        request[request.size - 2] = ((port shr 8) and 0xFF).toByte()
        request[request.size - 1] = (port and 0xFF).toByte()
        channel.write(ByteBuffer.wrap(request))

        val reply = readFully(channel, 4)
        val replyVersion = reply[0].toInt() and 0xFF
        val status = reply[1].toInt() and 0xFF
        if (replyVersion != VERSION) throw Socks5Exception("proxy replied with version $replyVersion")
        if (status != REPLY_SUCCEEDED) {
            throw Socks5Exception("proxy refused the connection: ${replyErrors[status] ?: "unknown error $status"}")
        }
        consumeBoundAddress(channel, reply[3].toInt() and 0xFF)
    }

    /** The address the proxy bound; it is not needed, but it must leave the stream. */
    private fun consumeBoundAddress(channel: SocketChannel, addressType: Int) {
        when (addressType) {
            ADDRESS_IPV4 -> readFully(channel, 4 + 2)
            ADDRESS_DOMAIN -> {
                val length = readFully(channel, 1)[0].toInt() and 0xFF
                readFully(channel, length + 2)
            }
            else -> readFully(channel, 16 + 2)
        }
    }

    /**
     * Destinations arrive from the tunnel as literal addresses, almost always IPv4.
     * An IPv4 literal is sent as `ATYP 1`, which every SOCKS5 server accepts; anything else
     * is sent as a domain name.
     */
    private fun encodeAddress(host: String): ByteArray {
        val octets = host.split('.')
        if (octets.size == 4) {
            val values = octets.mapNotNull { octet ->
                octet.toIntOrNull()?.takeIf { it in 0..255 && octet.isNotEmpty() }
            }
            if (values.size == 4) {
                return byteArrayOf(
                    ADDRESS_IPV4.toByte(),
                    values[0].toByte(), values[1].toByte(), values[2].toByte(), values[3].toByte(),
                )
            }
        }
        val bytes = host.toByteArray(Charsets.US_ASCII)
        require(bytes.size <= 255) { "destination name is too long: $host" }
        return byteArrayOf(ADDRESS_DOMAIN.toByte(), bytes.size.toByte()) + bytes
    }

    private fun readFully(channel: SocketChannel, count: Int): ByteArray {
        val buffer = ByteBuffer.allocate(count)
        while (buffer.hasRemaining()) {
            if (channel.read(buffer) < 0) throw Socks5Exception("proxy closed the connection mid-handshake")
        }
        return buffer.array()
    }
}

internal class Socks5Exception(message: String) : Exception(message)
