import Foundation
import NIOCore
import NIOHTTP1
import NIOSSL
import FlowKit
import RuleKit

/// Pipes raw bytes between the client and upstream sides of an opaque (non-decrypted) tunnel.
///
/// Inbound bytes are consumed here and never propagated down the pipeline, so the stale
/// HTTP handler that follows it never sees them.
final class TunnelRelayHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private let lock = NSLock()
    private var peerChannel: Channel?
    /// Bytes that arrived before the peer was wired up, flushed as soon as it is.
    private var pending: [ByteBuffer] = []

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
}

/// Handles HTTP on a client-facing connection, forwarding each request upstream.
///
/// One instance handles either plain proxied requests (`tunnel == nil`) or requests
/// arriving inside a decrypted CONNECT tunnel (`tunnel != nil`).
final class HTTPForwardHandler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    /// Held weakly on purpose. A handler lives in a child channel's pipeline, which is owned
    /// by an event loop; holding the engine strongly would let the loop become the engine's
    /// last owner and destroy it *on* the loop, where its blocking shutdown traps. The app
    /// owns the engine, and a handler simply stops working if it goes away.
    private weak var engine: ProxyEngine?
    private var tunnel: (host: String, port: Int)?
    private var requestHead: HTTPRequestHead?
    private var bodyBuffer: ByteBuffer?
    private var bodyBytes = 0
    /// Retains delayed Map Local writes: a `Scheduled` cancels itself on deinit, so without
    /// a reference the response would never be sent. Kept per connection, because a
    /// keep-alive client can have more than one delayed response in flight.
    private var pendingWrites: [PendingLocalWrite] = []

    init(engine: ProxyEngine, tunnel: (host: String, port: Int)?) {
        self.engine = engine
        self.tunnel = tunnel
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard let engine else {
            context.close(promise: nil)
            return
        }
        switch unwrapInboundIn(data) {
        case .head(let head):
            requestHead = head
            bodyBuffer = context.channel.allocator.buffer(capacity: 0)
            bodyBytes = 0

        case .body(var buffer):
            bodyBytes += buffer.readableBytes
            guard bodyBytes <= engine.configuration.maxRequestBodyBytes else {
                respond(on: context.channel, status: .payloadTooLarge, message: "Request body exceeds the configured limit")
                return
            }
            bodyBuffer?.writeBuffer(&buffer)

        case .end:
            guard let head = requestHead else { return }
            let body = bodyBuffer.map { Data($0.readableBytesView) } ?? Data()
            requestHead = nil
            bodyBuffer = nil
            if head.method == .CONNECT, tunnel == nil {
                handleConnect(context: context, head: head)
            } else {
                forward(context: context, head: head, body: body)
            }
        }
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        engine?.emit(.diagnostic("client connection error [\(tunnel?.host ?? "-")]: \(error)"))
        context.close(promise: nil)
    }

    func channelInactive(context: ChannelHandlerContext) {
        // A delayed write has nobody left to serve once the client is gone.
        pendingWrites.removeAll()
        context.fireChannelInactive()
    }

    // MARK: - CONNECT / MITM

    private func handleConnect(context: ChannelHandlerContext, head: HTTPRequestHead) {
        guard let target = TargetParser.resolveConnectTarget(head.uri) else {
            respond(on: context.channel, status: .badRequest, message: "Invalid CONNECT target: \(head.uri)")
            return
        }
        guard let engine else {
            context.close(promise: nil)
            return
        }
        let channel = context.channel
        let decrypt = engine.sslProxyingPolicy.shouldDecrypt(host: target.host)

        // Stop reading so the client's TLS ClientHello cannot be consumed by the HTTP codec.
        channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }

        // Acknowledge the tunnel through the HTTP encoder. `Content-Length: 0` stops the
        // encoder from framing the 200 as chunked, which would otherwise leak a chunk
        // terminator into the byte stream ahead of the TLS handshake.
        var responseHead = HTTPResponseHead(
            version: .http1_1,
            status: .custom(code: 200, reasonPhrase: "Connection Established")
        )
        responseHead.headers.add(name: "Content-Length", value: "0")
        context.write(wrapOutboundOut(.head(responseHead)), promise: nil)

        let flushed = context.writeAndFlush(wrapOutboundOut(.end(nil)))
        let prepared: EventLoopFuture<NIOSSLContext?>
        if decrypt {
            prepared = flushed.flatMap { _ -> EventLoopFuture<NIOSSLContext?> in
                let promise = channel.eventLoop.makePromise(of: NIOSSLContext?.self)
                Task {
                    do {
                        promise.succeed(try await engine.mitmContext(forHost: target.host))
                    } catch {
                        promise.fail(error)
                    }
                }
                return promise.futureResult
            }
        } else {
            prepared = flushed.map { _ -> NIOSSLContext? in nil }
        }

        prepared.whenComplete { result in
            switch result {
            case .success(let sslContext):
                // Reconfigure once this callback has unwound. NIO's request decoder stops
                // parsing for good after a CONNECT (it treats it as an upgrade), so the
                // codec is replaced; this handler stays put and switches into tunnel mode.
                channel.eventLoop.execute {
                    if let sslContext {
                        self.tunnel = target
                        engine.beginInterceptedTunnel(channel: channel, sslContext: sslContext, frontend: self, host: target.host)
                    } else {
                        engine.beginOpaqueTunnel(channel: channel, target: target)
                    }
                }
            case .failure(let error):
                engine.emit(.diagnostic("MITM setup failed for \(target.host): \(error)"))
                channel.close(promise: nil)
            }
        }
    }

    // MARK: - Forwarding

    private func forward(context: ChannelHandlerContext, head: HTTPRequestHead, body: Data) {
        guard let engine else {
            context.close(promise: nil)
            return
        }
        let channel = context.channel

        let resolved: ResolvedTarget
        if let tunnel {
            resolved = ResolvedTarget(scheme: "https", host: tunnel.host, port: tunnel.port, path: head.uri, isIntercepted: true)
        } else if let target = TargetParser.resolveProxyTarget(head) {
            resolved = target
        } else {
            respond(on: channel, status: .badRequest, message: "Cannot determine the target host for \(head.uri)")
            return
        }

        var headers = FlowKit.HTTPHeaders(nio: head.headers)
        headers.remove(name: "Proxy-Connection")
        headers["Host"] = resolved.hostHeader

        var timing = FlowTiming()
        timing.requestSent = Date()
        let request = HTTPRequest(
            method: head.method.rawValue,
            scheme: resolved.scheme,
            host: resolved.host,
            port: resolved.port,
            path: resolved.path,
            httpVersion: head.version.flowString,
            headers: headers,
            body: body
        )
        let recorder = FlowRecorder(
            flow: Flow(
                request: request,
                timing: timing,
                isIntercepted: resolved.isIntercepted,
                clientAddress: Self.clientAddress(channel)
            ),
            onEmit: { flow in engine.emitFlow(flow) }
        )

        // A Map Local rule answers before we ever dial upstream. A rule whose content
        // cannot be read is reported and then ignored, so the request falls through to
        // the remote server, which is the behaviour ProxyMaxx documents for a missing directory.
        if let outcome = engine.localResolution(for: request) {
            switch outcome {
            case .served(let resolution):
                serveLocal(resolution, on: channel, keepAlive: head.isKeepAlive, suppressBody: head.method == .HEAD, recorder: recorder)
                return
            case .unusable(let ruleName, let reason):
                engine.emit(.diagnostic("Map Local rule \"\(ruleName)\" skipped: \(reason)"))
            }
        }

        var upstreamHead = HTTPRequestHead(version: head.version, method: head.method, uri: resolved.path)
        upstreamHead.headers = headers.nio

        engine.connectUpstream(
            host: resolved.host,
            port: resolved.port,
            useTLS: resolved.isTLS,
            serverHostname: resolved.host
        ) { upstreamChannel in
            let upstream = UpstreamHandler(
                clientChannel: channel,
                recorder: recorder,
                engine: engine,
                clientKeepAlive: head.isKeepAlive,
                host: resolved.host
            )
            return upstreamChannel.pipeline.addHandler(HTTPRequestEncoder(), name: ProxyEngine.HandlerName.upstreamEncoder)
                // `.forwardBytes` is what makes a WebSocket work: after a `101` the
                // decoder stops parsing and hands whatever it buffered to the relay.
                .flatMap {
                    upstreamChannel.pipeline.addHandler(
                        ByteToMessageHandler(HTTPResponseDecoder(leftOverBytesStrategy: .forwardBytes)),
                        name: ProxyEngine.HandlerName.upstreamDecoder
                    )
                }
                .flatMap { upstreamChannel.pipeline.addHandler(upstream, name: ProxyEngine.HandlerName.upstream) }
        }.flatMap { upstreamChannel -> EventLoopFuture<Void> in
            upstreamChannel.write(NIOAny(HTTPClientRequestPart.head(upstreamHead)), promise: nil)
            if body.isEmpty {
                return upstreamChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
            }
            var buffer = upstreamChannel.allocator.buffer(capacity: body.count)
            buffer.writeBytes(body)
            upstreamChannel.write(NIOAny(HTTPClientRequestPart.body(.byteBuffer(buffer))), promise: nil)
            return upstreamChannel.writeAndFlush(NIOAny(HTTPClientRequestPart.end(nil)))
        }.whenFailure { error in
            recorder.fail("\(error)")
            self.respond(on: channel, status: .badGateway, message: "Upstream error: \(error)")
        }
    }

    // MARK: - Map Local

    /// Answer a request from a Map Local rule.
    ///
    /// A configured delay holds the write back without blocking the event loop; the
    /// scheduled task is retained because NIO cancels an unreferenced one on deinit.
    private func serveLocal(
        _ resolution: MapLocalResolution,
        on channel: Channel,
        keepAlive: Bool,
        suppressBody: Bool,
        recorder: FlowRecorder
    ) {
        let write = { [weak self] in
            guard let self else { return }
            self.writeLocalResponse(
                resolution,
                on: channel,
                keepAlive: keepAlive,
                suppressBody: suppressBody,
                recorder: recorder
            )
        }
        if resolution.delay > 0 {
            // Drop what has already run, then hold this one until it does.
            pendingWrites.removeAll { $0.isDone }
            let pending = PendingLocalWrite()
            pending.scheduled = channel.eventLoop.scheduleTask(in: .milliseconds(Int64(resolution.delay * 1000))) { [weak pending] in
                pending?.isDone = true
                write()
            }
            pendingWrites.append(pending)
        } else {
            write()
        }
    }

    private func writeLocalResponse(
        _ resolution: MapLocalResolution,
        on channel: Channel,
        keepAlive: Bool,
        suppressBody: Bool,
        recorder: FlowRecorder
    ) {
        let response = resolution.response
        let forbidsBody = response.statusCode == 204
            || response.statusCode == 304
            || (100..<200).contains(response.statusCode)

        var headers = response.headers.nio
        // The proxy frames the body itself, so any framing the file carried is discarded
        // and replaced with an explicit length. Mirrors what the upstream relay relies on.
        headers.remove(name: "Transfer-Encoding")
        if forbidsBody {
            headers.remove(name: "Content-Length")
        } else {
            headers.replaceOrAdd(name: "Content-Length", value: "\(response.body.count)")
        }

        recorder.serveLocal(response, source: resolution.sourceDescription, delay: resolution.delay)

        let head = HTTPResponseHead(
            version: .http1_1,
            status: HTTPResponseStatus(statusCode: response.statusCode),
            headers: headers
        )
        channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
        if !response.body.isEmpty, !forbidsBody, !suppressBody {
            var buffer = channel.allocator.buffer(capacity: response.body.count)
            buffer.writeBytes(response.body)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
        }
        channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
            if !keepAlive { channel.close(promise: nil) }
        }
    }

    /// Send a plain-text error response and close the client connection.
    ///
    /// Safe to call from any thread: upstream failures are reported from the upstream
    /// channel's event loop, so the write is hopped onto the client channel's loop.
    private func respond(on channel: Channel, status: HTTPResponseStatus, message: String) {
        let write = {
            var headers = NIOHTTP1.HTTPHeaders()
            headers.add(name: "Content-Type", value: "text/plain; charset=utf-8")
            headers.add(name: "Connection", value: "close")
            let bytes = Array(message.utf8)
            headers.add(name: "Content-Length", value: "\(bytes.count)")
            let head = HTTPResponseHead(version: .http1_1, status: status, headers: headers)
            var buffer = channel.allocator.buffer(capacity: bytes.count)
            buffer.writeBytes(bytes)
            channel.write(NIOAny(HTTPServerResponsePart.head(head)), promise: nil)
            channel.write(NIOAny(HTTPServerResponsePart.body(.byteBuffer(buffer))), promise: nil)
            channel.writeAndFlush(NIOAny(HTTPServerResponsePart.end(nil))).whenComplete { _ in
                channel.close(promise: nil)
            }
        }
        if channel.eventLoop.inEventLoop {
            write()
        } else {
            channel.eventLoop.execute(write)
        }
    }

    static func clientAddress(_ channel: Channel) -> String? {
        guard let remote = channel.remoteAddress else { return nil }
        let ip = remote.ipAddress ?? "?"
        let port = remote.port.map(String.init) ?? "?"
        return "\(ip):\(port)"
    }
}

/// Holds one delayed Map Local write.
///
/// The handler keeps these alive so the scheduled task is not cancelled before it runs;
/// `isDone` lets the next request on the same connection drop the ones that have fired.
private final class PendingLocalWrite {
    var scheduled: Scheduled<Void>?
    var isDone = false
}
