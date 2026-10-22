package com.proxymaxx.vpn.vpn

import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Test

/**
 * The client retransmits whenever the first answer is slower than its retransmission timer,
 * and on a tunnel that answer is slow by construction: the proxy is dialled and a leaf
 * certificate minted before anything can come back. Every repeat that reached the proxy
 * would sit inside the stream as a second copy of a record header, so this trimming is
 * load-bearing rather than an optimisation.
 */
class InboundStreamTest {

    @Test
    fun `opening on a syn expects the byte after it`() {
        val stream = InboundStream()

        stream.open(4096)

        assertEquals(4097L, stream.next)
    }

    @Test
    fun `a segment at the next sequence is forwarded whole`() {
        val stream = InboundStream(initialSequence = 100)
        val payload = "hello".toByteArray()

        val fresh = stream.accept(100, payload)

        assertArrayEquals(payload, fresh)
        assertEquals(105L, stream.next)
    }

    @Test
    fun `a repeat of an acknowledged segment is dropped`() {
        val stream = InboundStream(initialSequence = 100)
        stream.accept(100, ByteArray(536))

        val fresh = stream.accept(100, ByteArray(536))

        assertNull(fresh)
        assertEquals(636L, stream.next)
    }

    @Test
    fun `a partial repeat keeps only the bytes that were never sent`() {
        val stream = InboundStream(initialSequence = 100)
        stream.accept(100, ByteArray(536))

        val fresh = stream.accept(100, ByteArray(800) { 7 })

        assertArrayEquals(ByteArray(264) { 7 }, fresh)
        assertEquals(900L, stream.next)
    }

    @Test
    fun `a segment starting past the next byte is left for the peer to fill`() {
        val stream = InboundStream(initialSequence = 100)

        val fresh = stream.accept(200, ByteArray(10))

        assertNull(fresh)
        assertEquals("the acknowledgement must still ask for 100", 100L, stream.next)
    }

    @Test
    fun `sequence arithmetic survives the 32 bit wrap`() {
        // The five bytes that end exactly on the wrap: the stream continues at zero.
        val lastFive = 0xFFFFFFFFL - 4L
        val stream = InboundStream(initialSequence = lastFive)

        assertArrayEquals(ByteArray(5), stream.accept(lastFive, ByteArray(5)))
        assertEquals(0L, stream.next)

        assertNull("a segment past the wrap counts as delivered", stream.accept(lastFive, ByteArray(5)))
        assertArrayEquals(ByteArray(4) { 9 }, stream.accept(0, ByteArray(4) { 9 }))
        assertEquals(4L, stream.next)
    }
}
