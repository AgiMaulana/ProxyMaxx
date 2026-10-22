package com.proxymaxx.vpn.vpn

/**
 * Pulls the server name out of a TLS ClientHello.
 *
 * A tunnel only ever sees destination *addresses*, so a connection to
 * `142.250.66.100:443` would reach the proxy as a bare literal. That is useless for
 * hostname rules, for SNI-based filtering, and for readability in the flow list — so before
 * the proxy connection is made, the first bytes the client sends are inspected. For TLS
 * that is the ClientHello, and it names the host the client actually intends to reach.
 *
 * Only the ClientHello is parsed, and nothing is decrypted: the record stays untouched on
 * the wire. Non-TLS traffic simply keeps its literal address.
 */
internal object TlsClientHello {
    private const val RECORD_HANDSHAKE = 0x16
    private const val HANDSHAKE_CLIENT_HELLO = 0x01
    private const val EXTENSION_SERVER_NAME = 0x0000
    private const val NAME_TYPE_HOST_NAME = 0x00
    private const val RANDOM_LENGTH = 32

    fun serverName(record: ByteArray): String? {
        if (record.size < 9) return null
        if (record[0].toInt() and 0xFF != RECORD_HANDSHAKE) return null
        if (record[1].toInt() and 0xFF != 0x03) return null
        if (record[5].toInt() and 0xFF != HANDSHAKE_CLIENT_HELLO) return null
        // Handshake body: version (2) + random (32), then the session id.
        var index = 5 + 4 + 2 + RANDOM_LENGTH
        if (index >= record.size) return null
        index += 1 + (record[index].toInt() and 0xFF)
        if (index + 2 > record.size) return null
        index += 2 + readShort(record, index)
        if (index >= record.size) return null
        index += 1 + (record[index].toInt() and 0xFF)
        if (index + 2 > record.size) return null

        val extensionsEnd = minOf(index + 2 + readShort(record, index), record.size)
        index += 2
        while (index + 4 <= extensionsEnd) {
            val type = readShort(record, index)
            val length = readShort(record, index + 2)
            index += 4
            if (index + length > extensionsEnd) return null
            if (type == EXTENSION_SERVER_NAME) return parseServerName(record, index, index + length)
            index += length
        }
        return null
    }

    /**
     * Total bytes of the first TLS record in `bytes`, header included, or null when the
     * five-byte header has not fully arrived or the bytes are not a handshake record.
     *
     * The name sits at the end of the record, and a record can arrive across several TCP
     * segments. Knowing its declared length is what lets the tunnel wait for all of it
     * before it has to name the destination for the proxy.
     */
    fun firstRecordLength(bytes: ByteArray): Int? {
        if (bytes.size < 5) return null
        if (bytes[0].toInt() and 0xFF != RECORD_HANDSHAKE) return null
        if (bytes[1].toInt() and 0xFF != 0x03) return null
        return 5 + readShort(bytes, 3)
    }

    private fun parseServerName(record: ByteArray, start: Int, end: Int): String? {
        if (start + 2 > end) return null
        val listEnd = minOf(start + 2 + readShort(record, start), end)
        var index = start + 2
        while (index + 3 <= listEnd) {
            val nameType = record[index].toInt() and 0xFF
            val length = readShort(record, index + 1)
            index += 3
            if (index + length > listEnd) return null
            if (nameType == NAME_TYPE_HOST_NAME) {
                return String(record, index, length, Charsets.US_ASCII)
            }
            index += length
        }
        return null
    }

    private fun readShort(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)
}
