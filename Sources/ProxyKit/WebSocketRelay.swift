import Foundation
import NIOCore
import FlowKit

/// Relays a connection that upgraded to WebSocket and records the frames it carries.
///
/// Every byte is forwarded verbatim: the proxy does not need to understand extensions
/// or permessage-deflate, and the parser only observes a copy.
final class WebSocketRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let direction: WebSocketMessage.Direction
    private let recorder: FlowRecorder
    private let lock = NSLock()
    private var peerChannel: Channel?
    /// Bytes that arrived before the peer was wired up, flushed as soon as it is.
    private var pending: [ByteBuffer] = []
    private var parser = WebSocketFrameParser()

    init(direction: WebSocketMessage.Direction, recorder: FlowRecorder) {
        self.direction = direction
        self.recorder = recorder
    }

    var peer: Channel? {
        get {
            lock.lock(); defer { lock.unlock() }
            return peerChannel
        }
        set {
            lock.lock()
            peerChannel = newValue
            let buffered = pending
            pending.removeAll()
            lock.unlock()
            guard let newValue else { return }
            for buffer in buffered {
                newValue.writeAndFlush(NIOAny(IOData.byteBuffer(buffer)), promise: nil)
            }
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)

        for frame in parser.consume(buffer) {
            recorder.appendWebSocketMessage(
                WebSocketMessage(
                    direction: direction,
                    opcode: Self.name(forOpcode: frame.opcode),
                    isFinal: frame.isFinal,
                    payload: frame.payload
                )
            )
        }

        lock.lock()
        if let peer = peerChannel {
            lock.unlock()
            peer.writeAndFlush(NIOAny(IOData.byteBuffer(buffer)), promise: nil)
        } else {
            pending.append(buffer)
            lock.unlock()
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        peer?.close(promise: nil)
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        peer?.close(promise: nil)
        context.close(promise: nil)
    }

    private static func name(forOpcode opcode: UInt8) -> String {
        switch opcode {
        case 0x0: return "continuation"
        case 0x1: return "text"
        case 0x2: return "binary"
        case 0x8: return "close"
        case 0x9: return "ping"
        case 0xA: return "pong"
        default: return "reserved"
        }
    }
}
