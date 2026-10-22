import Foundation
import NIOCore

/// One WebSocket frame as it appeared on the wire.
struct WebSocketFrame: Sendable {
    let isFinal: Bool
    let opcode: UInt8
    let payload: Data
}

/// Incrementally splits a byte stream into WebSocket frames.
///
/// This observes a copy of the bytes the relay already forwarded, so a frame the
/// parser cannot make sense of never changes what the peer receives.
struct WebSocketFrameParser {
    /// Frames up to this size are parsed. Anything larger stops capture for the
    /// direction instead of buffering without bound.
    static let maximumFrameBytes = 16 * 1024 * 1024

    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var disabled = false

    mutating func consume(_ source: ByteBuffer) -> [WebSocketFrame] {
        guard !disabled else { return [] }
        buffer.append(contentsOf: source.readableBytesView)

        var frames: [WebSocketFrame] = []
        while let frame = nextFrame() {
            frames.append(frame)
        }
        if readIndex > 0 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        return frames
    }

    private mutating func nextFrame() -> WebSocketFrame? {
        guard buffer.count - readIndex >= 2 else { return nil }

        let firstByte = buffer[readIndex]
        let secondByte = buffer[readIndex + 1]
        let isFinal = firstByte & 0x80 != 0
        let opcode = firstByte & 0x0F
        let isMasked = secondByte & 0x80 != 0
        var payloadLength = Int(secondByte & 0x7F)
        var headerEnd = readIndex + 2

        switch payloadLength {
        case 126:
            guard buffer.count - headerEnd >= 2 else { return nil }
            payloadLength = Int(buffer[headerEnd]) << 8 | Int(buffer[headerEnd + 1])
            headerEnd += 2

        case 127:
            guard buffer.count - headerEnd >= 8 else { return nil }
            var length: UInt64 = 0
            for offset in 0..<8 {
                length = (length << 8) | UInt64(buffer[headerEnd + offset])
            }
            headerEnd += 8
            guard length <= UInt64(Self.maximumFrameBytes) else {
                disableCapture()
                return nil
            }
            payloadLength = Int(length)

        default:
            break
        }

        let maskLength = isMasked ? 4 : 0
        guard payloadLength <= Self.maximumFrameBytes else {
            disableCapture()
            return nil
        }
        guard buffer.count - headerEnd >= maskLength + payloadLength else { return nil }

        var mask: [UInt8] = []
        if isMasked {
            mask = Array(buffer[headerEnd..<(headerEnd + 4)])
            headerEnd += 4
        }

        var payload = Data(buffer[headerEnd..<(headerEnd + payloadLength)])
        if isMasked {
            payload.withUnsafeMutableBytes { bytes in
                for index in 0..<bytes.count {
                    bytes[index] ^= mask[index % 4]
                }
            }
        }

        readIndex = headerEnd + payloadLength
        return WebSocketFrame(isFinal: isFinal, opcode: opcode, payload: payload)
    }

    private mutating func disableCapture() {
        disabled = true
        buffer.removeAll(keepingCapacity: false)
        readIndex = 0
    }
}
