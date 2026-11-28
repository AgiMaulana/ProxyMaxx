import Foundation
import NIOCore
import NIOPosix
import NIOSSL
import NIOHTTP2
import NIOHPACK

/// A minimal HTTP/2 origin server for the Phase 0 fixtures (#79).
///
/// The integration suite's `OriginServer` speaks HTTP/1.1 only; the fixtures that pin
/// h2 behavior need a peer that genuinely speaks HTTP/2 over TLS with a configurable
/// ALPN offer. It answers every request with a fixed body, either as a plain response
/// or as a gRPC-style exchange that closes with `grpc-status` trailers, so the sample
/// traffic from the issue's test matrix can be exercised end to end.
final class H2TestServer {
    /// What the TLS handshake offers. `.none` configures no ALPN at all, matching the
    /// engine's own TLS contexts today.
    enum ALPNConfiguration {
        case h2Only
        case none
    }

    /// Response shape: a plain h2 response, or a gRPC-style one that carries the body
    /// as a DATA frame and closes with `grpc-status: 0` trailers.
    enum ResponseMode {
        case plain
        case grpc
    }

    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let tlsContext: NIOSSLContext
    private let body: String
    private let contentType: String
    private let mode: ResponseMode

    init(
        alpn: ALPNConfiguration,
        mode: ResponseMode = .plain,
        certificatePEM: String,
        privateKeyPEM: String,
        body: String,
        contentType: String = "application/json"
    ) throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.body = body
        self.contentType = contentType
        self.mode = mode

        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(certificatePEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(privateKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        configuration.minimumTLSVersion = .tlsv12
        switch alpn {
        case .h2Only:
            configuration.applicationProtocols = ["h2"]
        case .none:
            configuration.applicationProtocols = []
        }
        self.tlsContext = try NIOSSLContext(configuration: configuration)
    }

    /// Bind on an ephemeral loopback port and return it.
    func start() throws -> Int {
        let tlsContext = self.tlsContext
        let body = self.body
        let contentType = self.contentType
        let mode = self.mode
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: tlsContext), position: .first)
                    .flatMap { channel.pipeline.addHandler(NIOHTTP2Handler(mode: .server)) }
                    .flatMap { channel.pipeline.addHandler(H2OriginHandler(body: body, contentType: contentType, mode: mode), name: "h2-origin") }
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

/// Answers each complete h2 request stream with the server's fixed response.
///
/// The request is not inspected: the fixtures assert on what the *proxy* does with
/// the connection, not on what the origin received. Frames that are not headers or
/// data (settings, ping, window updates) are left to `NIOHTTP2Handler`.
private final class H2OriginHandler: ChannelInboundHandler {
    typealias InboundIn = HTTP2Frame

    private let body: String
    private let contentType: String
    private let mode: H2TestServer.ResponseMode
    /// Streams whose request headers have been seen; gRPC responses may arrive split
    /// across a DATA frame and the trailers, so completion is tracked per stream.
    private var awaitingBody: Set<HTTP2StreamID> = []

    init(body: String, contentType: String, mode: H2TestServer.ResponseMode) {
        self.body = body
        self.contentType = contentType
        self.mode = mode
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let frame = unwrapInboundIn(data)
        switch frame.payload {
        case .headers(let payload):
            guard payload.endStream else { return }
            respond(context: context, streamID: frame.streamID)
        case .data(let payload):
            guard payload.endStream else { return }
            respond(context: context, streamID: frame.streamID)
        default:
            break
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    private func respond(context: ChannelHandlerContext, streamID: HTTP2StreamID) {
        let channel = context.channel

        var headers = HPACKHeaders()
        headers.add(name: ":status", value: "200")
        headers.add(name: "content-type", value: contentType)
        let headFrame = HTTP2Frame(
            streamID: streamID,
            payload: .headers(.init(headers: headers, endStream: false))
        )
        channel.write(headFrame, promise: nil)

        var buffer = channel.allocator.buffer(capacity: body.utf8.count)
        buffer.writeString(body)
        switch mode {
        case .plain:
            let dataFrame = HTTP2Frame(
                streamID: streamID,
                payload: .data(.init(data: .byteBuffer(buffer), endStream: true))
            )
            channel.writeAndFlush(dataFrame, promise: nil)
        case .grpc:
            // gRPC frames the payload as a compressed-flag byte plus a four-byte big-endian
            // length, then closes the stream with status trailers.
            var grpcFrame = channel.allocator.buffer(capacity: body.utf8.count + 5)
            grpcFrame.writeInteger(UInt8(0))
            grpcFrame.writeInteger(UInt32(body.utf8.count))
            grpcFrame.writeBytes(body.utf8)
            let dataFrame = HTTP2Frame(
                streamID: streamID,
                payload: .data(.init(data: .byteBuffer(grpcFrame), endStream: false))
            )
            channel.write(dataFrame, promise: nil)

            var trailers = HPACKHeaders()
            trailers.add(name: "grpc-status", value: "0")
            let trailerFrame = HTTP2Frame(
                streamID: streamID,
                payload: .headers(.init(headers: trailers, endStream: true))
            )
            channel.writeAndFlush(trailerFrame, promise: nil)
        }
    }
}
