import Foundation
import Darwin
import NIOCore
import NIOPosix
import NIOHTTP1
import NIOSSL
import Logging
import CertKit
import FlowKit
import RuleKit

/// A local HTTP/HTTPS man-in-the-middle proxy.
///
/// The engine listens on a loopback port, terminates TLS for CONNECT tunnels using
/// locally-generated leaf certificates, forwards every request upstream, and reports
/// each transaction as a `Flow` through `onEvent`.
public final class ProxyEngine: @unchecked Sendable {
    enum HandlerName {
        static let decoder = "proxymaxx.http-decoder"
        static let encoder = "proxymaxx.http-encoder"
        static let frontend = "proxymaxx.frontend"
        static let mitmSSL = "proxymaxx.mitm-ssl"
        static let mitmDecoder = "proxymaxx.mitm-decoder"
        static let mitmEncoder = "proxymaxx.mitm-encoder"
        static let mitm = "proxymaxx.mitm"
        static let relay = "proxymaxx.relay"
        static let webSocket = "proxymaxx.websocket"
        static let upstream = "proxymaxx.upstream"
        static let upstreamDecoder = "proxymaxx.upstream-decoder"
        static let upstreamEncoder = "proxymaxx.upstream-encoder"
        static let socks = "proxymaxx.socks5"
    }

    private let policyLock = NSLock()
    private var _sslProxyingPolicy: SSLProxyingPolicy = .decryptAll

    /// Decides which hosts are decrypted (MITM'd) and which are tunnelled opaquely.
    /// Safe to mutate from any thread.
    public var sslProxyingPolicy: SSLProxyingPolicy {
        get {
            policyLock.lock(); defer { policyLock.unlock() }
            return _sslProxyingPolicy
        }
        set {
            policyLock.lock()
            _sslProxyingPolicy = newValue
            policyLock.unlock()
        }
    }

    private let mapLocalLock = NSLock()
    private var _mapLocalRules: [MapLocalRule] = []

    /// The Map Local rules to apply, in evaluation order. An empty list disables the tool.
    /// Safe to mutate from any thread.
    public var mapLocalRules: [MapLocalRule] {
        get {
            mapLocalLock.lock(); defer { mapLocalLock.unlock() }
            return _mapLocalRules
        }
        set {
            mapLocalLock.lock()
            _mapLocalRules = newValue
            mapLocalLock.unlock()
        }
    }

    /// The local response for `request`, if a Map Local rule matches it.
    ///
    /// Only decrypted requests reach this: a host excluded from SSL Proxying is relayed
    /// opaquely, so its requests are never visible to rewrite.
    func localResolution(for request: HTTPRequest) -> MapLocalOutcome? {
        MapLocalResponder.resolve(request: request, rules: mapLocalRules)
    }

    private let resolverLock = NSLock()
    private var _clientResolver: (any ClientAppResolving)?

    /// Names the process behind each client connection. Without one, flows still carry the
    /// client's socket address but no app. Safe to set from any thread.
    public var clientResolver: (any ClientAppResolving)? {
        get {
            resolverLock.lock(); defer { resolverLock.unlock() }
            return _clientResolver
        }
        set {
            resolverLock.lock()
            _clientResolver = newValue
            resolverLock.unlock()
        }
    }

    public private(set) var configuration: ProxyConfiguration
    /// Receives flow and lifecycle events. Called from arbitrary threads.
    public var onEvent: ((ProxyEvent) -> Void)?

    let group: EventLoopGroup
    let leafCache: LeafCertificateCache
    private let contextCache: MITMContextCache
    private let clientTLSContext: NIOSSLContext
    private let logger: Logger
    private var serverChannel: Channel?
    private var socksChannel: Channel?
    private let ownsGroup: Bool

    public init(
        configuration: ProxyConfiguration = ProxyConfiguration(),
        authority: CertificateAuthority,
        group: EventLoopGroup? = nil
    ) throws {
        let resolvedGroup: EventLoopGroup
        let owns: Bool
        if let group {
            resolvedGroup = group
            owns = false
        } else {
            resolvedGroup = MultiThreadedEventLoopGroup(numberOfThreads: max(2, System.coreCount / 2))
            owns = true
        }

        let leafCache = LeafCertificateCache(authority: authority)

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = configuration.verifyUpstreamCertificates ? .fullVerification : .none
        let clientContext = try NIOSSLContext(configuration: tls)

        self.configuration = configuration
        self.group = resolvedGroup
        self.ownsGroup = owns
        self.leafCache = leafCache
        self.contextCache = MITMContextCache(leafCache: leafCache)
        self.clientTLSContext = clientContext
        self.logger = Logger(label: "oss.proxymaxx.proxykit.engine")
    }

    deinit {
        let httpChannel = serverChannel
        let socks = socksChannel
        let group = self.group
        let owns = ownsGroup
        guard httpChannel != nil || socks != nil || owns else { return }

        // This routinely runs on an event loop: NIO futures and channel callbacks hold the
        // engine, and their last release happens there. Waiting on a channel from inside a
        // loop, or shutting the group down, deadlocks — so the teardown is handed to a queue
        // that can never be one. `stop()` is still the deterministic path; this is only the
        // safety net for an engine that was never stopped.
        DispatchQueue.global().async {
            try? httpChannel?.close().wait()
            try? socks?.close().wait()
            if owns {
                try? group.syncShutdownGracefully()
            }
        }
    }

    public var isRunning: Bool { serverChannel?.isActive ?? false }

    public var boundPort: Int? { serverChannel?.localAddress?.port }

    /// Port the SOCKS5 listener actually bound, once `start()` has run.
    ///
    /// May differ from `configuration.socksPort`: ProxyMaxx's own SOCKS service carries a
    /// "should auto-select port" flag, and so does this one — a SOCKS port already taken by
    /// a running ProxyMaxx must not stop the HTTP proxy from starting.
    public private(set) var boundSocksPort: Int?

    // MARK: - Lifecycle

    public func start() throws {
        guard serverChannel == nil else { return }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ProxyKitError.tlsSetup("engine deallocated"))
                }
                return self.configureClientPipeline(channel)
            }

        let channel = try bootstrap.bind(host: configuration.host, port: configuration.port).wait()
        serverChannel = channel
        if let port = channel.localAddress?.port, port != configuration.port {
            configuration.port = port
        }
        startSOCKS5()
        logger.info("proxy listening", metadata: ["host": .string(configuration.host), "port": .stringConvertible(configuration.port)])
        onEvent?(.stateChanged(isRunning: true, port: configuration.port))
    }

    /// Serve the SOCKS5 listener that Android clients reach the proxy through.
    ///
    /// Binding here is deliberately not fatal: a SOCKS port already taken by another proxy
    /// must not stop the HTTP proxy from starting, so the port is re-selected instead.
    private func startSOCKS5() {
        guard let requested = configuration.socksPort else { return }

        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.backlog, value: 256)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelOption(ChannelOptions.maxMessagesPerRead, value: 16)
            .childChannelInitializer { [weak self] channel in
                guard let self else {
                    return channel.eventLoop.makeFailedFuture(ProxyKitError.tlsSetup("engine deallocated"))
                }
                return self.resolveClientApp(for: channel).flatMap { clientApp in
                    channel.pipeline.addHandler(
                        SOCKS5Handler(engine: self, clientApp: clientApp), name: HandlerName.socks
                    )
                }
            }

        let channel: Channel
        do {
            channel = try bootstrap.bind(host: configuration.host, port: requested).wait()
        } catch {
            guard let fallback = try? bootstrap.bind(host: configuration.host, port: 0).wait() else {
                emit(.diagnostic("could not start the SOCKS5 listener on port \(requested): \(error)"))
                return
            }
            emit(.diagnostic("SOCKS5 port \(requested) was in use; listening on \(fallback.localAddress?.port ?? 0) instead"))
            channel = fallback
        }

        socksChannel = channel
        boundSocksPort = channel.localAddress?.port
        logger.info("socks5 listening", metadata: ["port": .stringConvertible(boundSocksPort ?? 0)])
    }

    public func stop() {
        guard let channel = serverChannel else { return }
        try? channel.close().wait()
        serverChannel = nil
        if let socksChannel {
            try? socksChannel.close().wait()
        }
        socksChannel = nil
        boundSocksPort = nil
        onEvent?(.stateChanged(isRunning: false, port: configuration.port))
    }

    public func waitUntilClosed() throws {
        try serverChannel?.closeFuture.wait()
    }

    // MARK: - Pipeline

    private func resolveClientApp(for channel: Channel) -> EventLoopFuture<ClientApp?> {
        guard let resolver = clientResolver,
              let client = channel.remoteAddress, let proxy = channel.localAddress,
              let clientAddress = Self.numericAddress(client), let clientPort = client.port,
              let proxyAddress = Self.numericAddress(proxy), let proxyPort = proxy.port
        else { return channel.eventLoop.makeSucceededFuture(nil) }

        let promise = channel.eventLoop.makePromise(of: ClientApp?.self)
        resolver.resolveClientApp(
            clientAddress: clientAddress, clientPort: clientPort,
            proxyAddress: proxyAddress, proxyPort: proxyPort
        ) { promise.succeed($0) }
        return promise.futureResult
    }

    private static func numericAddress(_ address: SocketAddress) -> String? {
        guard let ip = address.ipAddress else { return nil }
        if case .v6(let ipv6) = address, ipv6.address.sin6_scope_id != 0 {
            return "\(ip)%\(ipv6.address.sin6_scope_id)"
        }
        return ip
    }

    private func configureClientPipeline(_ channel: Channel) -> EventLoopFuture<Void> {
        // NIO waits for the child initializer before registering the channel for reads.
        resolveClientApp(for: channel).flatMap { clientApp in
            let handler = HTTPForwardHandler(engine: self, tunnel: nil, clientApp: clientApp)
            return channel.pipeline.addHandler(HTTPResponseEncoder(), name: HandlerName.encoder)
                .flatMap { channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()), name: HandlerName.decoder) }
                .flatMap { channel.pipeline.addHandler(handler, name: HandlerName.frontend) }
        }
    }

    /// Open a connection to an upstream server, optionally wrapped in TLS.
    func connectUpstream(
        host: String,
        port: Int,
        useTLS: Bool,
        serverHostname: String,
        initializer: @escaping (Channel) -> EventLoopFuture<Void>
    ) -> EventLoopFuture<Channel> {
        let clientContext = clientTLSContext
        let bootstrap = ClientBootstrap(group: group)
            .channelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .connectTimeout(.seconds(Int64(configuration.connectTimeoutSeconds)))
            .channelInitializer { channel in
                let tlsFuture: EventLoopFuture<Void>
                if useTLS {
                    do {
                        // SNI must be omitted for IP literals; NIOSSL rejects them outright.
                        let sni = Self.isIPAddress(serverHostname) ? nil : serverHostname
                        let handler = try NIOSSLClientHandler(context: clientContext, serverHostname: sni)
                        tlsFuture = channel.pipeline.addHandler(handler, position: .first)
                    } catch {
                        return channel.eventLoop.makeFailedFuture(error)
                    }
                } else {
                    tlsFuture = channel.eventLoop.makeSucceededVoidFuture()
                }
                return tlsFuture.flatMap { initializer(channel) }
            }
        return bootstrap.connect(host: host, port: port)
    }

    // MARK: - Tunnel setup

    /// Hand a client channel over to an intercepted tunnel.
    ///
    /// `frontend` is where the decrypted HTTP is delivered and must already be installed.
    /// Whatever plaintext front end was there — the HTTP codecs, or the SOCKS5 handshake
    /// handler — is removed first, so `CONNECT` and SOCKS5 share one sequence and cannot
    /// drift apart.
    /// Returns the reconfiguration, so a caller holding bytes that must reach the new
    /// pipeline can wait for it rather than race it.
    ///
    /// `replay` is asked for its bytes where they are fired, not when the call is made. A
    /// hand-off waits on a certificate, and a caller that is still installed keeps buffering
    /// throughout that wait; reading the buffer at the switch carries the whole prefix
    /// instead of the part that happened to be there when the wait began.
    @discardableResult
    func beginInterceptedTunnel(
        channel: Channel,
        sslContext: NIOSSLContext,
        frontend: ChannelHandler,
        replay: @escaping () -> ByteBuffer? = { nil },
        host: String = "-"
    ) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        let chain = removePlaintextFrontEnd(from: channel)
            .flatMap { pipeline.addHandler(NIOSSLServerHandler(context: sslContext), name: HandlerName.mitmSSL, position: .first) }
            .flatMap { pipeline.addHandler(HTTPResponseEncoder(), name: HandlerName.mitmEncoder, position: .before(frontend)) }
            .flatMap { pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()), name: HandlerName.mitmDecoder, position: .before(frontend)) }
            .flatMap { Self.replay(replay(), into: channel) }
            .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }

        chain.whenComplete { result in
            switch result {
            case .success:
                channel.read()
            case .failure(let error):
                self.emit(.diagnostic("failed to start TLS on client connection [\(host)]: \(error)"))
                channel.close(promise: nil)
            }
        }
        return chain
    }

    /// Hand bytes that were read to classify a connection back to the pipeline.
    ///
    /// This must happen **before** reading resumes. Enabling `autoRead` and issuing a read
    /// happens further along the same chain, so replaying afterwards lets the socket deliver
    /// the rest of the ClientHello first — the head would then reach the TLS stack after the
    /// tail, and a handshake built on a reordered stream is correctly rejected. A client on
    /// this machine usually writes the whole hello in one go and hides the race; a tunnel
    /// relaying an emulator's TCP segments does not, which is where this showed up.
    private static func replay(_ buffer: ByteBuffer?, into channel: Channel) -> EventLoopFuture<Void> {
        if let buffer, buffer.readableBytes > 0 {
            channel.pipeline.fireChannelRead(NIOAny(buffer))
        }
        return channel.eventLoop.makeSucceededVoidFuture()
    }

    /// Take the plaintext front end out of the pipeline before a tunnel replaces it.
    ///
    /// Each removal is awaited rather than assumed. NIO only removes a handler that opts in,
    /// and refuses the rest outright, so a handler left behind would silently swallow every
    /// decrypted byte of the new tunnel.
    private func removePlaintextFrontEnd(from channel: Channel) -> EventLoopFuture<Void> {
        removeHandlers([HandlerName.decoder, HandlerName.encoder, HandlerName.socks], from: channel)
    }

    /// Remove any of `names` that are present, on the channel's event loop.
    ///
    /// `syncOperations` is only valid on the owning loop, and a WebSocket switch touches
    /// two channels that may sit on different loops, so the whole sequence is hopped
    /// onto each channel through `flatSubmit`.
    private func removeHandlers(_ names: [String], from channel: Channel) -> EventLoopFuture<Void> {
        channel.eventLoop.flatSubmit {
            let pipeline = channel.pipeline
            return names.reduce(channel.eventLoop.makeSucceededVoidFuture()) { chain, name in
                guard (try? pipeline.syncOperations.context(name: name)) != nil else { return chain }
                return chain.flatMap { pipeline.removeHandler(name: name) }
            }
        }
    }

    /// Relay the tunnel without decrypting it, for hosts excluded from SSL Proxying.
    @discardableResult
    func beginOpaqueTunnel(
        channel: Channel,
        target: (host: String, port: Int),
        replay: @escaping () -> ByteBuffer? = { nil }
    ) -> EventLoopFuture<Void> {
        let pipeline = channel.pipeline
        let clientRelay = TunnelRelayHandler()
        let upstreamRelay = TunnelRelayHandler()

        // Connect first and wire both ends before reading from the client, so the very
        // first TLS bytes are never dropped for want of a peer.
        let chain = removePlaintextFrontEnd(from: channel)
            .flatMap { _ in
                self.connectUpstream(host: target.host, port: target.port, useTLS: false, serverHostname: target.host) { upstream in
                    upstream.pipeline.addHandler(upstreamRelay, name: HandlerName.relay)
                }
            }
            .flatMap { upstream -> EventLoopFuture<Void> in
                clientRelay.peer = upstream
                upstreamRelay.peer = channel
                return pipeline.addHandler(clientRelay, name: HandlerName.relay, position: .first)
                    .flatMap { Self.replay(replay(), into: channel) }
                    .flatMap { channel.setOption(ChannelOptions.autoRead, value: true) }
            }

        chain.whenComplete { result in
            switch result {
            case .success:
                channel.read()
            case .failure(let error):
                self.emit(.diagnostic("opaque tunnel to \(target.host):\(target.port) failed: \(error)"))
                channel.close(promise: nil)
            }
        }
        return chain
    }

    // MARK: - WebSocket

    /// Continue a decrypted connection as a raw WebSocket relay after `101`.
    ///
    /// HTTP stops applying at the upgrade: the codecs are removed on both ends and the
    /// bytes are piped verbatim, while a parser observes them so the inspector can show
    /// the frames. Reads stay paused until both pipelines are raw, so nothing can reach
    /// an encoder that is about to be removed.
    func beginWebSocketRelay(
        client: Channel,
        upstream: Channel,
        recorder: FlowRecorder,
        host: String
    ) {
        let clientRelay = WebSocketRelayHandler(direction: .clientToServer, recorder: recorder)
        let upstreamRelay = WebSocketRelayHandler(direction: .serverToClient, recorder: recorder)
        clientRelay.peer = upstream
        upstreamRelay.peer = client

        let clientSwitch = removeHandlers(
            [HandlerName.mitmDecoder, HandlerName.mitmEncoder, HandlerName.decoder, HandlerName.encoder, HandlerName.frontend],
            from: client
        ).flatMap {
            client.pipeline.addHandler(clientRelay, name: HandlerName.webSocket)
        }

        clientSwitch
            .flatMap { self.switchUpstreamToRelay(upstream, relay: upstreamRelay) }
            .flatMap { client.setOption(ChannelOptions.autoRead, value: true) }
            .whenComplete { result in
                switch result {
                case .success:
                    client.read()
                case .failure(let error):
                    self.emit(.diagnostic("WebSocket relay setup failed [\(host)]: \(error)"))
                    client.close(promise: nil)
                    upstream.close(promise: nil)
                }
            }
    }

    /// Replace the upstream HTTP stack with the relay.
    ///
    /// The response decoder stopped parsing at the upgrade, so removing it with
    /// `.forwardBytes` hands any frames it already buffered to the relay instead of
    /// dropping them. The relay must be in place before that removal.
    private func switchUpstreamToRelay(_ upstream: Channel, relay: WebSocketRelayHandler) -> EventLoopFuture<Void> {
        removeHandlers([HandlerName.upstream], from: upstream)
            .flatMap { upstream.pipeline.addHandler(relay, name: HandlerName.webSocket) }
            .flatMap { self.removeHandlers([HandlerName.upstreamDecoder, HandlerName.upstreamEncoder], from: upstream) }
            .flatMap { upstream.setOption(ChannelOptions.autoRead, value: true) }
            .map { upstream.read() }
    }

    // MARK: - Events

    func emit(_ event: ProxyEvent) {
        if case .diagnostic(let message) = event {
            FileHandle.standardError.write(Data("[diag] \(message)\n".utf8))
        }
        onEvent?(event)
    }

    func emitFlow(_ flow: Flow) {
        onEvent?(.flow(flow))
    }

    /// Build (or reuse) the TLS context that presents a leaf certificate for `host`.
    func mitmContext(forHost host: String) async throws -> NIOSSLContext {
        try await contextCache.context(forHost: host)
    }

    /// True when `host` is an IPv4 or IPv6 literal rather than a DNS name.
    static func isIPAddress(_ host: String) -> Bool {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 { return true }
        var v6 = in6_addr()
        return inet_pton(AF_INET6, host, &v6) == 1
    }
}
