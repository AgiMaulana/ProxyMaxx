import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL

/// A minimal origin server used by the integration tests. It answers every request
/// with a fixed body so the proxy can be exercised end to end.
final class OriginServer {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let body: String
    private let contentType: String
    private let tlsContext: NIOSSLContext?

    init(tls: Bool, certificatePEM: String? = nil, privateKeyPEM: String? = nil, body: String, contentType: String = "application/json") throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.body = body
        self.contentType = contentType
        if tls, let certificatePEM, let privateKeyPEM {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8))
            let key = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(key)
            )
            configuration.minimumTLSVersion = .tlsv12
            self.tlsContext = try NIOSSLContext(configuration: configuration)
        } else {
            self.tlsContext = nil
        }
    }

    /// Bind on an ephemeral loopback port and return it.
    func start() throws -> Int {
        let body = self.body
        let contentType = self.contentType
        let tlsContext = self.tlsContext
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                var future = channel.eventLoop.makeSucceededVoidFuture()
                if let tlsContext {
                    future = future.flatMap { channel.pipeline.addHandler(NIOSSLServerHandler(context: tlsContext), position: .first) }
                }
                return future
                    .flatMap { channel.pipeline.addHandler(HTTPResponseEncoder()) }
                    .flatMap { channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder())) }
                    .flatMap { channel.pipeline.addHandler(OriginHandler(body: body, contentType: contentType), name: "origin-handler") }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = channel
        return channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

private final class OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let body: String
    private let contentType: String

    init(body: String, contentType: String) {
        self.body = body
        self.contentType = contentType
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }
        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Type", value: contentType)
        headers.add(name: "Content-Length", value: "\(body.utf8.count)")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        var buffer = context.channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        context.write(wrapOutboundOut(.head(head)), promise: nil)
        context.write(wrapOutboundOut(.body(.byteBuffer(buffer))), promise: nil)
        context.writeAndFlush(wrapOutboundOut(.end(nil)), promise: nil)
    }
}
