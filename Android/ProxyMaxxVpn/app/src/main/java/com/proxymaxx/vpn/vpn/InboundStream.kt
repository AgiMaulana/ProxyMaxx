package com.proxymaxx.vpn.vpn

/**
 * The client's side of one tunnel TCP connection, reduced to the question that matters:
 * how far it has been forwarded, and which bytes of a new segment are actually new.
 *
 * A client retransmits whenever the first answer outruns its retransmission timer, and it
 * does: the proxy connection has to be dialled and a leaf certificate minted before a byte
 * can come back, while a handshake over an unmeasured path floors that timer at 200 ms.
 * Forwarding a repeat verbatim splices a second copy of the ClientHello into the middle of
 * the first, and the proxy then reads the tail of that record as the next record header —
 * bytes land where a TLS version belongs and it closes with an error that names nothing
 * which is actually wrong. Trimming here is what keeps the byte stream the proxy sees
 * identical to the one the client wrote, whatever the retransmission does.
 */
internal class InboundStream(initialSequence: Long = 0) {

    /** Sequence number of the next byte expected from the client. */
    var next: Long = initialSequence and SEQUENCE_MASK
        private set

    /** Opens the stream on a SYN, whose sequence number sits one below the first data byte. */
    fun open(sequence: Long) {
        next = (sequence + 1) and SEQUENCE_MASK
    }

    /**
     * The part of `payload`, starting at `sequence`, that has not been forwarded yet.
     *
     * Returns null when the segment repeats bytes already sent, or when it starts past the
     * next byte expected. A hole cannot be repaired from here, so it is left unfilled and the
     * acknowledgement keeps asking for it rather than the stream being forwarded out of order.
     */
    fun accept(sequence: Long, payload: ByteArray): ByteArray? {
        val start = sequence and SEQUENCE_MASK
        val distance = (start - next) and SEQUENCE_MASK
        if (distance == 0L) {
            next = (start + payload.size) and SEQUENCE_MASK
            return payload
        }
        if (distance < SEQUENCE_HALF) return null
        val alreadySent = (-distance) and SEQUENCE_MASK
        if (alreadySent >= payload.size) return null
        next = (start + payload.size) and SEQUENCE_MASK
        return payload.copyOfRange(alreadySent.toInt(), payload.size)
    }

    private companion object {
        /** Sequence numbers are 32-bit and wrap, so comparisons stay in that space. */
        const val SEQUENCE_MASK = 0xFFFFFFFFL
        const val SEQUENCE_HALF = 0x80000000L
    }
}
