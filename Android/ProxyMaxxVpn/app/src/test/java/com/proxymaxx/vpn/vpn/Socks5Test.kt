package com.proxymaxx.vpn.vpn

import java.io.InputStream
import java.net.InetSocketAddress
import java.net.ServerSocket
import java.nio.channels.SocketChannel
import java.util.concurrent.CompletableFuture
import java.util.concurrent.TimeUnit
import kotlin.concurrent.thread
import org.junit.Assert.assertEquals
import org.junit.Test

/**
 * Exercises the handshake against a real socket, so the exact bytes on the wire are pinned.
 * The proxy in the middle is what makes hostname rules and readable flows possible, so a
 * change that silently altered this framing would be a real regression.
 */
class Socks5Test {

    @Test
    fun `negotiates no-auth and issues an IPv4 CONNECT`() {
        val server = ServerSocket(0)
        val requestBytes = CompletableFuture<ByteArray>()

        thread(isDaemon = true) {
            server.accept().use { socket ->
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                assertBytes(byteArrayOf(5, 1, 0), readExactly(input, 3))
                output.write(byteArrayOf(5, 0))
                output.flush()

                requestBytes.complete(readExactly(input, 10))
                output.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
                output.flush()
            }
        }

        connectAndHandshake(server, "142.250.66.100", 443)

        val request = requestBytes.get(5, TimeUnit.SECONDS)
        assertBytes(byteArrayOf(5, 1, 0, 1), request.copyOfRange(0, 4))
        assertBytes(byteArrayOf(142.toByte(), 250.toByte(), 66, 100), request.copyOfRange(4, 8))
        assertEquals(443, ((request[8].toInt() and 0xFF) shl 8) or (request[9].toInt() and 0xFF))
    }

    @Test
    fun `sends a domain name when the destination is not a literal address`() {
        val server = ServerSocket(0)
        val requestBytes = CompletableFuture<ByteArray>()
        val name = "api.example.com"

        thread(isDaemon = true) {
            server.accept().use { socket ->
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                readExactly(input, 3)
                output.write(byteArrayOf(5, 0))
                output.flush()
                requestBytes.complete(readExactly(input, 4 + 1 + name.length + 2))
                output.write(byteArrayOf(5, 0, 0, 1, 0, 0, 0, 0, 0, 0))
                output.flush()
            }
        }

        connectAndHandshake(server, name, 8443)

        val request = requestBytes.get(5, TimeUnit.SECONDS)
        assertBytes(byteArrayOf(5, 1, 0, 3), request.copyOfRange(0, 4))
        assertEquals(name.length.toByte(), request[4])
        assertEquals(name, String(request.copyOfRange(5, 5 + name.length), Charsets.US_ASCII))
    }

    @Test(expected = Socks5Exception::class)
    fun `reports a refusal from the proxy instead of failing silently`() {
        val server = ServerSocket(0)
        thread(isDaemon = true) {
            server.accept().use { socket ->
                val input = socket.getInputStream()
                val output = socket.getOutputStream()
                readExactly(input, 3)
                output.write(byteArrayOf(5, 0))
                output.flush()
                readExactly(input, 10)
                output.write(byteArrayOf(5, 5, 0, 1, 0, 0, 0, 0, 0, 0)) // 5 = connection refused
                output.flush()
            }
        }
        connectAndHandshake(server, "142.250.66.100", 443)
    }

    @Test(expected = Socks5Exception::class)
    fun `reports a proxy that demands authentication`() {
        val server = ServerSocket(0)
        thread(isDaemon = true) {
            server.accept().use { socket ->
                readExactly(socket.getInputStream(), 3)
                socket.getOutputStream().write(byteArrayOf(5, 2)) // 2 = username/password
                socket.getOutputStream().flush()
            }
        }
        connectAndHandshake(server, "142.250.66.100", 443)
    }

    private fun connectAndHandshake(server: ServerSocket, host: String, port: Int) {
        val channel = SocketChannel.open()
        channel.configureBlocking(true)
        channel.connect(InetSocketAddress("127.0.0.1", server.localPort))
        try {
            Socks5.connect(channel, host, port)
        } finally {
            channel.close()
            server.close()
        }
    }

    private fun readExactly(input: InputStream, count: Int): ByteArray {
        val buffer = ByteArray(count)
        var read = 0
        while (read < count) {
            val chunk = input.read(buffer, read, count - read)
            if (chunk < 0) error("the peer closed the connection after $read of $count bytes")
            read += chunk
        }
        return buffer
    }

    private fun assertBytes(expected: ByteArray, actual: ByteArray) {
        assertEquals(expected.toList(), actual.toList())
    }
}
