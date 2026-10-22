package com.proxymaxx.vpn.vpn

import java.net.InetAddress
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Assert.fail
import org.junit.Test

class Ipv4Test {

    private val source = InetAddress.getByName("10.255.0.1")
    private val destination = InetAddress.getByName("142.250.66.100")

    @Test
    fun `tcp packet carries a valid ipv4 header checksum`() {
        val packet = Ipv4.buildTcpPacket(
            source = source,
            destination = destination,
            sourcePort = 41234,
            destinationPort = 443,
            sequence = 1000,
            acknowledgement = 77,
            flags = Ipv4.TCP_FLAG_SYN or Ipv4.TCP_FLAG_ACK,
        )

        assertTrue("header checksum must verify", verifies(packet, 0, Ipv4.HEADER_LENGTH))
    }

    @Test
    fun `tcp packet carries a valid transport checksum including the payload`() {
        val payload = "GET / HTTP/1.1\r\nHost: example.com\r\n\r\n".toByteArray()
        val packet = Ipv4.buildTcpPacket(
            source = source,
            destination = destination,
            sourcePort = 41234,
            destinationPort = 80,
            sequence = 1000,
            acknowledgement = 77,
            flags = Ipv4.TCP_FLAG_PSH or Ipv4.TCP_FLAG_ACK,
            payload = payload,
        )

        val transport = packet.copyOfRange(Ipv4.HEADER_LENGTH, packet.size)
        val pseudo = pseudoHeader(source, destination, Ipv4.PROTOCOL_TCP, transport.size)
        assertTrue("TCP checksum must verify", verifies(pseudo + transport))
    }

    @Test
    fun `udp packet carries a valid transport checksum`() {
        val packet = Ipv4.buildUdpPacket(
            source = source,
            destination = destination,
            sourcePort = 5353,
            destinationPort = 53,
            payload = byteArrayOf(1, 2, 3, 4),
        )

        val transport = packet.copyOfRange(Ipv4.HEADER_LENGTH, packet.size)
        val pseudo = pseudoHeader(source, destination, Ipv4.PROTOCOL_UDP, transport.size)
        assertTrue("UDP checksum must verify", verifies(pseudo + transport))
    }

    @Test
    fun `a syn ack advertises the segment size in an option of its own`() {
        val packet = Ipv4.buildTcpPacket(
            source = source,
            destination = destination,
            sourcePort = 443,
            destinationPort = 41234,
            sequence = 1000,
            acknowledgement = 77,
            flags = Ipv4.TCP_FLAG_SYN or Ipv4.TCP_FLAG_ACK,
            options = Ipv4.mssOption(),
        )

        // A TCP header with options is longer than one without, and says so in its data offset.
        assertEquals(Ipv4.TCP_HEADER_LENGTH + 4, dataOffset(packet))
        assertEquals(2, packet[Ipv4.HEADER_LENGTH].toInt())
        assertEquals(4, packet[Ipv4.HEADER_LENGTH + 1].toInt())
        assertEquals(Ipv4.MAX_SEGMENT_SIZE, Ipv4.MAX_TCP_PAYLOAD)
        val advertised = ((packet[Ipv4.HEADER_LENGTH + 2].toInt() and 0xFF) shl 8) or
            (packet[Ipv4.HEADER_LENGTH + 3].toInt() and 0xFF)
        assertEquals(Ipv4.MAX_SEGMENT_SIZE, advertised)

        // The option is part of the header, so it has to be inside both checksums.
        assertTrue("header checksum must cover the options", verifies(packet, 0, Ipv4.HEADER_LENGTH))
        val transport = packet.copyOfRange(Ipv4.HEADER_LENGTH, packet.size)
        val pseudo = pseudoHeader(source, destination, Ipv4.PROTOCOL_TCP, transport.size)
        assertTrue("TCP checksum must cover the options", verifies(pseudo + transport))
    }

    @Test
    fun `options that are not a whole number of words are refused`() {
        try {
            Ipv4.buildTcpPacket(
                source = source,
                destination = destination,
                sourcePort = 443,
                destinationPort = 41234,
                sequence = 1000,
                acknowledgement = 77,
                flags = Ipv4.TCP_FLAG_SYN or Ipv4.TCP_FLAG_ACK,
                options = byteArrayOf(2, 4, 0),
            )
            fail("a three-byte option list would make the data offset fractional")
        } catch (expected: IllegalArgumentException) {
            assertTrue(expected.message!!.contains("whole number of words"))
        }
    }

    @Test
    fun `tcp round trips through build and parse`() {
        val packet = Ipv4.buildTcpPacket(
            source = source,
            destination = destination,
            sourcePort = 41234,
            destinationPort = 443,
            sequence = 1000,
            acknowledgement = 77,
            flags = Ipv4.TCP_FLAG_PSH or Ipv4.TCP_FLAG_ACK,
            payload = "hello".toByteArray(),
        )

        val header = Ipv4.header(packet, packet.size)
        assertNotNull(header)
        assertEquals(Ipv4.HEADER_LENGTH, header!!.headerLength)
        assertEquals(packet.size, header.totalLength)
        assertEquals(Ipv4.PROTOCOL_TCP, header.protocol)
        assertEquals(source, header.source)
        assertEquals(destination, header.destination)

        val segment = Ipv4.tcpSegment(packet, header)
        assertNotNull(segment)
        assertEquals(41234, segment!!.sourcePort)
        assertEquals(443, segment.destinationPort)
        assertEquals(1000L, segment.sequence)
        assertEquals(77L, segment.acknowledgement)
        assertEquals("hello", String(segment.payload))
    }

    @Test
    fun `udp round trips through build and parse`() {
        val packet = Ipv4.buildUdpPacket(
            source = source,
            destination = destination,
            sourcePort = 5353,
            destinationPort = 53,
            payload = byteArrayOf(9, 8, 7),
        )

        val header = Ipv4.header(packet, packet.size)
        assertNotNull(header)
        val segment = Ipv4.udpSegment(packet, header!!)
        assertNotNull(segment)
        assertEquals(5353, segment!!.sourcePort)
        assertEquals(53, segment.destinationPort)
        assertEquals(3, segment.payload.size)
    }

    @Test
    fun `non ipv4 traffic is rejected rather than guessed at`() {        // An IPv6 header: version nibble 6, which the tunnel must not try to interpret.
        val ipv6 = ByteArray(48).also { it[0] = 0x60.toByte() }
        assertNull(Ipv4.header(ipv6, ipv6.size))
    }

    @Test
    fun `truncated packets are rejected`() {
        val packet = Ipv4.buildTcpPacket(
            source = source,
            destination = destination,
            sourcePort = 1,
            destinationPort = 2,
            sequence = 0,
            acknowledgement = 0,
            flags = Ipv4.TCP_FLAG_ACK,
        )
        assertNull(Ipv4.header(packet, 8))
    }

    @Test
    fun `a chunk never exceeds one tun packet`() {
        // What one read from the proxy can hand back: a whole TLS flight, well past the MTU.
        val flight = ByteArray(1887) { it.toByte() }
        val chunks = Ipv4.tcpPayloadChunks(flight)

        assertEquals(Ipv4.MAX_TCP_PAYLOAD, chunks.first().size)
        assertTrue("every chunk must fit the MTU", chunks.all { it.size <= Ipv4.MAX_TCP_PAYLOAD })
        assertEquals(flight.size, chunks.sumOf { it.size })
        assertTrue("the split must preserve the bytes in order", chunks.reduce { a, b -> a + b }.contentEquals(flight))
    }

    @Test
    fun `an empty read yields no chunks`() {
        assertTrue(Ipv4.tcpPayloadChunks(ByteArray(0)).isEmpty())
    }

    @Test
    fun `a payload that already fits is not split`() {
        val payload = ByteArray(Ipv4.MAX_TCP_PAYLOAD) { 1 }
        val chunks = Ipv4.tcpPayloadChunks(payload)
        assertEquals(1, chunks.size)
        assertEquals(Ipv4.MAX_TCP_PAYLOAD, chunks.single().size)
    }

    /** One's-complement sum over the buffer must come out as all ones when it is valid. */
    private fun verifies(bytes: ByteArray): Boolean {        var sum = 0
        var index = 0
        while (index + 1 < bytes.size) {
            sum += ((bytes[index].toInt() and 0xFF) shl 8) or (bytes[index + 1].toInt() and 0xFF)
            index += 2
        }
        if (index < bytes.size) sum += (bytes[index].toInt() and 0xFF) shl 8
        while (sum shr 16 != 0) sum = (sum and 0xFFFF) + (sum shr 16)
        return sum == 0xFFFF
    }

    private fun verifies(packet: ByteArray, from: Int, to: Int): Boolean =
        verifies(packet.copyOfRange(from, to))

    /** The TCP header length in bytes, as the data offset field states it. */
    private fun dataOffset(packet: ByteArray): Int =
        (packet[Ipv4.HEADER_LENGTH + 12].toInt() and 0xF0) shr 2

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
}
