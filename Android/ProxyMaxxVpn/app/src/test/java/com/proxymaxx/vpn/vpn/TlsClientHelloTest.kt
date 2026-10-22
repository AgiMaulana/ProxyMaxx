package com.proxymaxx.vpn.vpn

import java.io.ByteArrayOutputStream
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

class TlsClientHelloTest {

    @Test
    fun `reads the server name out of a client hello`() {
        val record = clientHello(serverName = "api.example.com")
        assertEquals("api.example.com", TlsClientHello.serverName(record))
    }

    @Test
    fun `survives a session id, which shifts every later offset`() {
        val record = clientHello(serverName = "secure.example.com", sessionId = ByteArray(32) { 7 })
        assertEquals("secure.example.com", TlsClientHello.serverName(record))
    }

    @Test
    fun `returns null when the handshake carries no server name`() {
        assertNull(TlsClientHello.serverName(clientHello(serverName = null)))
    }

    @Test
    fun `ignores anything that is not a tls handshake`() {
        assertNull(TlsClientHello.serverName("GET / HTTP/1.1\r\n\r\n".toByteArray()))
        assertNull(TlsClientHello.serverName(ByteArray(0)))
        assertNull(TlsClientHello.serverName(byteArrayOf(0x16, 0x03, 0x01, 0, 0)))
    }

    @Test
    fun `does not read past a truncated record`() {
        val full = clientHello(serverName = "api.example.com")
        assertNull(TlsClientHello.serverName(full.copyOfRange(0, full.size / 2)))
    }

    @Test
    fun `reports the full record length so a split hello can be waited for`() {
        val record = clientHello(serverName = "api.example.com")
        assertEquals(record.size, TlsClientHello.firstRecordLength(record))
    }

    @Test
    fun `record length is unavailable until the header has arrived`() {
        val record = clientHello(serverName = "api.example.com")
        assertNull(TlsClientHello.firstRecordLength(record.copyOfRange(0, 4)))
    }

    @Test
    fun `record length is refused for something that is not a tls handshake`() {
        assertNull(TlsClientHello.firstRecordLength("GET / HTTP/1.1\r\n\r\n".toByteArray()))
        assertNull(TlsClientHello.firstRecordLength(ByteArray(0)))
    }

    private fun clientHello(serverName: String?, sessionId: ByteArray = ByteArray(0)): ByteArray {
        val extensions = ByteArrayOutputStream()
        if (serverName != null) {
            val name = serverName.toByteArray(Charsets.US_ASCII)
            val entry = byteArrayOf(0, ((name.size shr 8) and 0xFF).toByte(), (name.size and 0xFF).toByte()) + name
            val list = byteArrayOf(
                ((entry.size shr 8) and 0xFF).toByte(),
                (entry.size and 0xFF).toByte(),
            ) + entry
            extensions.write(byteArrayOf(0, 0)) // server_name
            extensions.write(
                byteArrayOf(((list.size shr 8) and 0xFF).toByte(), (list.size and 0xFF).toByte()),
            )
            extensions.write(list)
        }
        val extensionBytes = extensions.toByteArray()

        val body = ByteArrayOutputStream()
        body.write(byteArrayOf(3, 3))
        body.write(ByteArray(32))
        body.write(sessionId.size)
        body.write(sessionId)
        body.write(byteArrayOf(0, 2, 0, 0x2f))
        body.write(byteArrayOf(1, 0))
        body.write(
            byteArrayOf(
                ((extensionBytes.size shr 8) and 0xFF).toByte(),
                (extensionBytes.size and 0xFF).toByte(),
            ),
        )
        body.write(extensionBytes)
        val bodyBytes = body.toByteArray()

        val handshake = ByteArrayOutputStream()
        handshake.write(1)
        handshake.write(
            byteArrayOf(
                ((bodyBytes.size shr 16) and 0xFF).toByte(),
                ((bodyBytes.size shr 8) and 0xFF).toByte(),
                (bodyBytes.size and 0xFF).toByte(),
            ),
        )
        handshake.write(bodyBytes)
        val handshakeBytes = handshake.toByteArray()

        val record = ByteArrayOutputStream()
        record.write(0x16)
        record.write(byteArrayOf(3, 1))
        record.write(
            byteArrayOf(
                ((handshakeBytes.size shr 8) and 0xFF).toByte(),
                (handshakeBytes.size and 0xFF).toByte(),
            ),
        )
        record.write(handshakeBytes)
        return record.toByteArray()
    }
}
