import XCTest
import NIOCore
@testable import ProxyKit

final class WebSocketFrameParserTests: XCTestCase {
    func testParsesUnmaskedTextFrame() {
        var parser = WebSocketFrameParser()
        let frames = parser.consume(makeFrame(opcode: 0x1, payload: Array("hello".utf8), masked: false))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.opcode, 0x1)
        XCTAssertEqual(frames.first?.isFinal, true)
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "hello")
    }

    func testUnmasksClientFrame() {
        var parser = WebSocketFrameParser()
        let frames = parser.consume(makeFrame(opcode: 0x1, payload: Array("{\"type\":\"ping\"}".utf8), masked: true))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "{\"type\":\"ping\"}")
    }

    func testWaitsForCompleteFrameAcrossReads() {
        var parser = WebSocketFrameParser()
        let bytes = makeBytes(opcode: 0x1, payload: Array("split frame".utf8), masked: true)
        var first = ByteBufferAllocator().buffer(capacity: 4)
        first.writeBytes(bytes.prefix(4))

        XCTAssertTrue(parser.consume(first).isEmpty)

        var second = ByteBufferAllocator().buffer(capacity: bytes.count - 4)
        second.writeBytes(bytes.dropFirst(4))
        let frames = parser.consume(second)

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first.map { String(decoding: $0.payload, as: UTF8.self) }, "split frame")
    }

    func testParsesMultipleFramesInOneRead() {
        var parser = WebSocketFrameParser()
        var buffer = ByteBufferAllocator().buffer(capacity: 64)
        buffer.writeBytes(makeBytes(opcode: 0x1, payload: Array("one".utf8), masked: true))
        buffer.writeBytes(makeBytes(opcode: 0x2, payload: [0x00, 0x01], masked: false))

        let frames = parser.consume(buffer)

        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].opcode, 0x1)
        XCTAssertEqual(frames[1].opcode, 0x2)
        XCTAssertEqual(frames[1].payload, Data([0x00, 0x01]))
    }

    func testHandlesExtendedPayloadLength() {
        var parser = WebSocketFrameParser()
        let payload = Array(repeating: UInt8(0x61), count: 300)
        let frames = parser.consume(makeFrame(opcode: 0x2, payload: payload, masked: true))

        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames.first?.payload.count, 300)
        XCTAssertEqual(frames.first?.payload, Data(payload))
    }

    func testMarksContinuationAndControlFrames() {
        var parser = WebSocketFrameParser()
        var buffer = ByteBufferAllocator().buffer(capacity: 32)
        buffer.writeBytes(makeBytes(opcode: 0x0, payload: Array("tail".utf8), masked: false, isFinal: false))
        buffer.writeBytes(makeBytes(opcode: 0x9, payload: Array("hb".utf8), masked: false))

        let frames = parser.consume(buffer)

        XCTAssertEqual(frames.map(\.opcode), [0x0, 0x9])
        XCTAssertEqual(frames.first?.isFinal, false)
    }

    // MARK: - Helpers

    private func makeFrame(opcode: UInt8, payload: [UInt8], masked: Bool, isFinal: Bool = true) -> ByteBuffer {
        var buffer = ByteBufferAllocator().buffer(capacity: payload.count + 14)
        buffer.writeBytes(makeBytes(opcode: opcode, payload: payload, masked: masked, isFinal: isFinal))
        return buffer
    }

    private func makeBytes(opcode: UInt8, payload: [UInt8], masked: Bool, isFinal: Bool = true) -> [UInt8] {
        var bytes: [UInt8] = [isFinal ? 0x80 | opcode : opcode]
        let maskBit: UInt8 = masked ? 0x80 : 0

        if payload.count < 126 {
            bytes.append(maskBit | UInt8(payload.count))
        } else if payload.count <= 0xFFFF {
            bytes.append(maskBit | 126)
            bytes.append(UInt8((payload.count >> 8) & 0xFF))
            bytes.append(UInt8(payload.count & 0xFF))
        } else {
            bytes.append(maskBit | 127)
            let length = UInt64(payload.count)
            for shift in stride(from: 56, through: 0, by: -8) {
                bytes.append(UInt8((length >> UInt64(shift)) & 0xFF))
            }
        }

        var body = payload
        if masked {
            let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
            bytes.append(contentsOf: key)
            body = payload.enumerated().map { $0.element ^ key[$0.offset % 4] }
        }
        bytes.append(contentsOf: body)
        return bytes
    }
}
