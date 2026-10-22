import Foundation
import NIOCore
import NIOHTTP1
import FlowKit

/// Relays the upstream response back to the client while recording it into a flow.
final class UpstreamHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPClientResponsePart
    typealias OutboundOut = HTTPClientRequestPart

    private let clientChannel: Channel
    private let recorder: FlowRecorder
    private let engine: ProxyEngine
    private let clientKeepAlive: Bool
    private let host: String
    private var finished = false
    private var isWebSocketUpgrade = false

    init(clientChannel: Channel, recorder: FlowRecorder, engine: ProxyEngine, clientKeepAlive: Bool, host: String) {
        self.clientChannel = clientChannel
        self.recorder = recorder
        self.engine = engine
        self.clientKeepAlive = clientKeepAlive
        self.host = host
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        switch unwrapInboundIn(data) {
        case .head(let responseHead):
            recorder.responseHead(responseHead)
            isWebSocketUpgrade = responseHead.status.code == 101
            if isWebSocketUpgrade {
                // Close the tap on both directions before the pipelines are rebuilt:
                // the codecs are about to be replaced by raw relays, and a frame that
                // arrives in between would be parsed as an HTTP message.
                clientChannel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
                context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            }
            let serverHead = HTTPResponseHead(version: responseHead.version, status: responseHead.status, headers: responseHead.headers)
            clientChannel.write(NIOAny(HTTPServerResponsePart.head(serverHead)), promise: nil)

        case .body(let buffer):
            recorder.appendResponseBody(buffer.data)
            clientChannel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)

        case .end(let trailers):
            guard !finished else { return }
            finished = true
            recorder.complete()
            // The write completes on the client channel's event loop, so from the
            // callback only thread-safe `Channel` methods may be touched.
            let upstreamChannel = context.channel
            let switchingProtocols = isWebSocketUpgrade
            let host = self.host
            clientChannel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(trailers))).whenComplete { result in
                switch result {
                case .success where switchingProtocols:
                    self.engine.beginWebSocketRelay(
                        client: self.clientChannel,
                        upstream: upstreamChannel,
                        recorder: self.recorder,
                        host: host
                    )
                case .success:
                    upstreamChannel.close(promise: nil)
                    if !self.clientKeepAlive {
                        self.clientChannel.close(promise: nil)
                    }
                case .failure:
                    upstreamChannel.close(promise: nil)
                    self.clientChannel.close(promise: nil)
                }
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        guard !finished else { return }
        finished = true
        engine.emit(.diagnostic("upstream error: \(error)"))
        recorder.fail("\(error)")
        clientChannel.close(promise: nil)
        context.close(promise: nil)
    }
}
