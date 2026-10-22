package com.proxymaxx.vpn.vpn

import java.net.InetAddress
import java.nio.ByteBuffer

/** Decoded IPv4 header taken off the tunnel. */
internal data class Ipv4Header(
    val headerLength: Int,
    val totalLength: Int,
    val protocol: Int,
    val source: InetAddress,
    val destination: InetAddress,
)

/** Decoded TCP segment, with its payload copied out for convenience. */
internal data class TcpSegment(
    val sourcePort: Int,
    val destinationPort: Int,
    val sequence: Long,
    val acknowledgement: Long,
    val flags: Int,
    val payload: ByteArray,
) {
    val isSyn: Boolean get() = flags and Ipv4.TCP_FLAG_SYN != 0
    val isFin: Boolean get() = flags and Ipv4.TCP_FLAG_FIN != 0
    val isRst: Boolean get() = flags and Ipv4.TCP_FLAG_RST != 0
}

/** Decoded UDP datagram. */
internal data class UdpSegment(
    val sourcePort: Int,
    val destinationPort: Int,
    val payload: ByteArray,
)

/**
 * IPv4 + TCP/UDP framing.
 *
 * The tunnel only ever carries IPv4: the device routes `0.0.0.0/0` into it but the emulator's
 * network is IPv4, and anything else is dropped rather than guessed at. Packets are parsed
 * from the bytes the kernel hands us and rebuilt on the way back with correct header
 * checksums, because the kernel does not checksum what a user-space tunnel writes.
 */
internal object Ipv4 {
    const val HEADER_LENGTH = 20
    const val PROTOCOL_TCP = 6
    const val PROTOCOL_UDP = 17
    const val DEFAULT_TTL = 64
    const val TCP_HEADER_LENGTH = 20
    const val UDP_HEADER_LENGTH = 8

    /** MTU the tunnel interface is established with; the kernel rejects anything larger. */
    const val MTU = 1500

    /**
     * The largest TCP payload one tun packet can carry: the MTU less the IP and TCP headers.
     * Anything read from the proxy in a single go must be split to this before it is written
     * back, or the kernel drops the packet and the peer never sees it.
     */
    const val MAX_TCP_PAYLOAD = MTU - HEADER_LENGTH - TCP_HEADER_LENGTH

    const val TCP_FLAG_FIN = 0x01
    const val TCP_FLAG_SYN = 0x02
    const val TCP_FLAG_RST = 0x04
    const val TCP_FLAG_PSH = 0x08
    const val TCP_FLAG_ACK = 0x10

    /**
     * Largest segment we are willing to receive, advertised as the MSS option.
     *
     * Without it a peer falls back to the 536-byte default of RFC 1122, so a ClientHello
     * arrives as four segments instead of two — four chances for one of them to be
     * retransmitted while the proxy is still being dialled.
     */
    const val MAX_SEGMENT_SIZE = MTU - HEADER_LENGTH - TCP_HEADER_LENGTH

    fun header(packet: ByteArray, length: Int): Ipv4Header? {
        if (length < HEADER_LENGTH) return null
        val versionAndIhl = packet[0].toInt() and 0xFF
        if (versionAndIhl shr 4 != 4) return null
        val headerLength = (versionAndIhl and 0x0F) * 4
        if (headerLength < HEADER_LENGTH || length < headerLength) return null
        val totalLength = readUnsignedShort(packet, 2)
        if (totalLength < headerLength || totalLength > length) return null
        val protocol = packet[9].toInt() and 0xFF
        val source = InetAddress.getByAddress(packet.copyOfRange(12, 16))
        val destination = InetAddress.getByAddress(packet.copyOfRange(16, 20))
        return Ipv4Header(headerLength, totalLength, protocol, source, destination)
    }

    fun tcpSegment(packet: ByteArray, header: Ipv4Header): TcpSegment? {
        val start = header.headerLength
        if (header.totalLength < start + TCP_HEADER_LENGTH) return null
        val dataOffset = (packet[start + 12].toInt() and 0xF0) shr 2
        if (dataOffset < TCP_HEADER_LENGTH) return null
        val payloadStart = start + dataOffset
        if (payloadStart > header.totalLength) return null
        return TcpSegment(
            sourcePort = readUnsignedShort(packet, start),
            destinationPort = readUnsignedShort(packet, start + 2),
            sequence = readUnsignedInt(packet, start + 4),
            acknowledgement = readUnsignedInt(packet, start + 8),
            flags = packet[start + 13].toInt() and 0xFF,
            payload = packet.copyOfRange(payloadStart, header.totalLength),
        )
    }

    fun udpSegment(packet: ByteArray, header: Ipv4Header): UdpSegment? {
        val start = header.headerLength
        if (header.totalLength < start + UDP_HEADER_LENGTH) return null
        val declaredLength = readUnsignedShort(packet, start + 4)
        val payloadEnd = minOf(header.totalLength, start + maxOf(declaredLength, UDP_HEADER_LENGTH))
        return UdpSegment(
            sourcePort = readUnsignedShort(packet, start),
            destinationPort = readUnsignedShort(packet, start + 2),
            payload = packet.copyOfRange(start + UDP_HEADER_LENGTH, payloadEnd),
        )
    }

    fun buildTcpPacket(
        source: InetAddress,
        destination: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        sequence: Long,
        acknowledgement: Long,
        flags: Int,
        window: Int = 65535,
        options: ByteArray? = null,
        payload: ByteArray? = null,
    ): ByteArray {
        val optionsLength = options?.size ?: 0
        require(optionsLength % 4 == 0) { "TCP options must be a whole number of words: $optionsLength" }
        val headerLength = TCP_HEADER_LENGTH + optionsLength
        val payloadLength = payload?.size ?: 0
        val tcpLength = headerLength + payloadLength
        val totalLength = HEADER_LENGTH + tcpLength
        val packet = ByteArray(totalLength)
        val buffer = ByteBuffer.wrap(packet)

        writeIpv4Header(buffer, source, destination, PROTOCOL_TCP, totalLength)
        writeIpv4Checksum(packet)

        buffer.putShort((sourcePort and 0xFFFF).toShort())
        buffer.putShort((destinationPort and 0xFFFF).toShort())
        buffer.putInt(sequence.toInt())
        buffer.putInt(acknowledgement.toInt())
        buffer.putShort((((headerLength / 4) shl 12) or (flags and 0xFF)).toShort())
        buffer.putShort((window and 0xFFFF).toShort())
        buffer.putShort(0)
        buffer.putShort(0)
        if (optionsLength > 0) buffer.put(options)
        if (payloadLength > 0) buffer.put(payload)

        val tcpChecksum = checksum(
            pseudoHeader(source, destination, PROTOCOL_TCP, tcpLength),
            packet.copyOfRange(HEADER_LENGTH, totalLength),
        )
        packet[HEADER_LENGTH + 16] = ((tcpChecksum shr 8) and 0xFF).toByte()
        packet[HEADER_LENGTH + 17] = (tcpChecksum and 0xFF).toByte()
        return packet
    }

    /** The MSS option — kind 2, length 4 — which is the only option the tunnel advertises. */
    fun mssOption(mss: Int = MAX_SEGMENT_SIZE): ByteArray = byteArrayOf(
        2,
        4,
        ((mss shr 8) and 0xFF).toByte(),
        (mss and 0xFF).toByte(),
    )

    fun buildUdpPacket(
        source: InetAddress,
        destination: InetAddress,
        sourcePort: Int,
        destinationPort: Int,
        payload: ByteArray,
    ): ByteArray {
        val udpLength = UDP_HEADER_LENGTH + payload.size
        val totalLength = HEADER_LENGTH + udpLength
        val packet = ByteArray(totalLength)
        val buffer = ByteBuffer.wrap(packet)

        writeIpv4Header(buffer, source, destination, PROTOCOL_UDP, totalLength)
        writeIpv4Checksum(packet)

        buffer.putShort((sourcePort and 0xFFFF).toShort())
        buffer.putShort((destinationPort and 0xFFFF).toShort())
        buffer.putShort(udpLength.toShort())
        buffer.putShort(0)
        buffer.put(payload)

        val udpChecksum = checksum(
            pseudoHeader(source, destination, PROTOCOL_UDP, udpLength),
            packet.copyOfRange(HEADER_LENGTH, totalLength),
        )
        // A zero checksum would mean "not computed", so UDP transmits 0xFFFF instead.
        val transmitted = if (udpChecksum == 0) 0xFFFF else udpChecksum
        packet[HEADER_LENGTH + 6] = ((transmitted shr 8) and 0xFF).toByte()
        packet[HEADER_LENGTH + 7] = (transmitted and 0xFF).toByte()
        return packet
    }

    /**
     * Patch the header checksum in place.
     *
     * It cannot simply be appended: the buffer is already positioned at the transport header
     * by the time the header is complete, and writing there would land on the source port.
     */
    private fun writeIpv4Checksum(packet: ByteArray) {
        val value = checksum(packet.copyOfRange(0, HEADER_LENGTH))
        packet[10] = ((value shr 8) and 0xFF).toByte()
        packet[11] = (value and 0xFF).toByte()
    }

    private fun writeIpv4Header(
        buffer: ByteBuffer,
        source: InetAddress,
        destination: InetAddress,
        protocol: Int,
        totalLength: Int,
    ) {
        buffer.put(0x45.toByte())
        buffer.put(0)
        buffer.putShort(totalLength.toShort())
        buffer.putShort(0)
        buffer.putShort(0x4000.toShort())
        buffer.put(DEFAULT_TTL.toByte())
        buffer.put(protocol.toByte())
        buffer.putShort(0)
        buffer.put(source.address)
        buffer.put(destination.address)
    }

    private fun pseudoHeader(
        source: InetAddress,
        destination: InetAddress,
        protocol: Int,
        length: Int,
    ): ByteArray {
        val header = ByteArray(12)
        System.arraycopy(source.address, 0, header, 0, 4)
        System.arraycopy(destination.address, 0, header, 4, 4)
        header[9] = protocol.toByte()
        header[10] = ((length shr 8) and 0xFF).toByte()
        header[11] = (length and 0xFF).toByte()
        return header
    }

    /**
     * Split a run of bytes into TCP payloads that each fit one tun packet.
     *
     * The kernel refuses a tun write larger than the interface MTU, and a single read from
     * the proxy routinely returns more than that. Empty input yields no chunks.
     */
    fun tcpPayloadChunks(data: ByteArray, maxPayload: Int = MAX_TCP_PAYLOAD): List<ByteArray> {
        require(maxPayload > 0) { "chunk size must be positive: $maxPayload" }
        if (data.isEmpty()) return emptyList()
        val chunks = ArrayList<ByteArray>((data.size + maxPayload - 1) / maxPayload)
        var offset = 0
        while (offset < data.size) {
            val end = minOf(offset + maxPayload, data.size)
            chunks.add(data.copyOfRange(offset, end))
            offset = end
        }
        return chunks
    }

    /** One's-complement sum over every block, then complemented — RFC 1071. */
    private fun checksum(vararg blocks: ByteArray): Int {
        var sum = 0
        for (block in blocks) {
            var index = 0
            while (index + 1 < block.size) {
                sum += readUnsignedShort(block, index)
                index += 2
            }
            if (index < block.size) sum += (block[index].toInt() and 0xFF) shl 8
        }
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum.inv() and 0xFFFF
    }

    private fun readUnsignedShort(bytes: ByteArray, offset: Int): Int =
        ((bytes[offset].toInt() and 0xFF) shl 8) or (bytes[offset + 1].toInt() and 0xFF)

    private fun readUnsignedInt(bytes: ByteArray, offset: Int): Long =
        ((bytes[offset].toLong() and 0xFF) shl 24) or
            ((bytes[offset + 1].toLong() and 0xFF) shl 16) or
            ((bytes[offset + 2].toLong() and 0xFF) shl 8) or
            (bytes[offset + 3].toLong() and 0xFF)
}
