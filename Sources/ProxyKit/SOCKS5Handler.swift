import Foundation
import NIOCore
import NIOSSL

/// Serves SOCKS5 so clients that will not use the system proxy can still be captured.
///
/// The Android tunnel is why this exists: it hands every TCP connection to port 80/443 to a
/// SOCKS5 listener, because by then the traffic is already inside the tunnel and no
/// app-level proxy setting could apply to it. ProxyMaxx ships a `SocksProxyService` for the
/// same reason.
///
/// Only `CONNECT` with no authentication is served, which is the whole of what the tunnel
/// sends. Both address forms it uses are understood: an IPv4 literal taken from the packet,
/// and a domain name recovered from the client's TLS ClientHello.
///
/// `RemovableChannelHandler` is required, not decorative: NIO refuses to take a handler out
/// of a live pipeline unless it opts in, and this one has to go the moment the tunnel is
/// handed over.
final class SOCKS5Handler: ChannelInboundHandler, RemovableChannelHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    /// SOCKS5 reply codes, numbered as the protocol defines them.
    private enum Reply: UInt8 {
        case succeeded = 0x00
        case generalFailure = 0x01
        case commandNotSupported = 0x07
        case addressTypeNotSupported = 0x08
    }

    private static let version: UInt8 = 0x05
    private static let methodNoAuthentication: UInt8 = 0x00
    private static let methodNoneAcceptable: UInt8 = 0xFF
    private static let commandConnect: UInt8 = 0x01
    private static let addressIPv4: UInt8 = 0x01
    private static let addressDomain: UInt8 = 0x03
    private static let addressIPv6: UInt8 = 0x04
    /// First byte of a TLS record carrying a handshake — how TLS announces itself.
    private static let tlsHandshakeRecord: UInt8 = 0x16
    private static let succeededReply: [UInt8] = [0x05, 0x00, 0x00, 0x01, 0, 0, 0, 0, 0, 0]

    /// Weak for the same reason as the HTTP handler: a pipeline is owned by an event loop,
    /// and a handler holding the engine strongly would let the loop become its last owner
    /// and tear it down on the loop, where the blocking shutdown traps.
    private weak var engine: ProxyEngine?
    private var pending: ByteBuffer?
    private var greetingComplete = false
    private var sniffing = false
    /// Set the moment the request is accepted: every byte from then on is tunnel payload.
    private var tunneling = false
    private var target: (host: String, port: Int)?

    init(engine: ProxyEngine) {
        self.engine = engine
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        var incoming = unwrapInboundIn(data)
        var buffer = pending ?? context.channel.allocator.buffer(capacity: 0)
        buffer.writeBuffer(&incoming)
        pending = buffer

        if sniffing {
            guard let engine, let target, buffer.readableBytes > 0 else { return }
            sniffing = false
            context.channel.setOption(ChannelOptions.autoRead, value: false).whenFailure { _ in }
            handOff(context: context, bytes: buffer, engine: engine, target: target)
            return
        }

        // Past the acknowledgement there is no second request to parse: these bytes are the
        // start of the stream the tunnel will carry. They stay buffered for the engine to
        // replay into the new pipeline, because a TLS record read as a SOCKS5 request is
        // garbage in both directions.
        guard !tunneling else { return }
        process(context: context)
    }

    /// Everything buffered for the tunnel so far, handed over and forgotten.
    ///
    /// The engine asks for this at the moment it swaps the pipeline in, so a read that
    /// arrives while the certificate is being prepared is carried over with the rest rather
    /// than stranded here.
    func takePending() -> ByteBuffer? {
        defer { pending = nil }
        return pending
    }

    func errorCaught(context: ChannelHandlerContext, error: Error) {
        context.close(promise: nil)
    }

    /// Buffered bytes are handed over by `takePending` before the removal is over, so the
    /// pipeline can let this handler go as soon as it is asked to.
    func removeHandler(
        context: ChannelHandlerContext,
        removalToken: ChannelHandlerContext.RemovalToken
    ) {
        context.leavePipeline(removalToken: removalToken)
    }

    /// Parses as much as has arrived. `pending` is only advanced once a step completes, so a
    /// half-delivered handshake is buffered rather than misread.
    private func process(context: ChannelHandlerContext) {
        guard var buffer = pending else { return }

        if !greetingComplete {
            // Each read only advances the local copy; `pending` moves forward only once a
            // whole step has arrived, so a partial handshake is buffered rather than misread.
            guard let version = buffer.readInteger(as: UInt8.self),
                  let methodCount = buffer.readInteger(as: UInt8.self),
                  let methods = buffer.readBytes(length: Int(methodCount))
            else { return }

            guard version == Self.version, methods.contains(Self.methodNoAuthentication) else {
                send(context: context, bytes: [Self.version, Self.methodNoneAcceptable])
                context.close(promise: nil)
                return
            }

            send(context: context, bytes: [Self.version, Self.methodNoAuthentication])
            pending = buffer
            greetingComplete = true
            process(context: context)
            return
        }

        guard let version = buffer.readInteger(as: UInt8.self),
              let command = buffer.readInteger(as: UInt8.self),
              buffer.readInteger(as: UInt8.self) != nil,
              let addressType = buffer.readInteger(as: UInt8.self)
        else { return }

        guard version == Self.version else {
            reject(context: context, code: .generalFailure)
            return
        }

        let host: String
        switch addressType {
        case Self.addressIPv4:
            guard let octets = buffer.readBytes(length: 4) else { return }
            host = octets.map(String.init).joined(separator: ".")
        case Self.addressDomain:
            guard let length = buffer.readInteger(as: UInt8.self),
                  let name = buffer.readBytes(length: Int(length))
            else { return }
            host = String(decoding: name, as: UTF8.self)
        case Self.addressIPv6:
            guard let octets = buffer.readBytes(length: 16) else { return }
            host = stride(from: 0, to: 16, by: 2)
                .map { String(format: "%x", (UInt16(octets[$0]) << 8) | UInt16(octets[$0 + 1])) }
                .joined(separator: ":")
        default:
            reject(context: context, code: .addressTypeNotSupported)
            return
        }

        guard let port = buffer.readInteger(as: UInt16.self), !host.isEmpty else {
            reject(context: context, code: .generalFailure)
            return
        }

        guard command == Self.commandConnect else {
            reject(context: context, code: .commandNotSupported)
            return
        }

        pending = buffer
        target = (host: host, port: Int(port))
        accept(context: context)
    }

    /// Acknowledge the request, which is all that is known so far.
    private func accept(context: ChannelHandlerContext) {
        guard let engine, let target else {
            context.close(promise: nil)
            return
        }
        // Committed before the asynchronous step below, not after it: from here every read
        // is tunnel payload, and one that lands during the acknowledgement must be buffered
        // rather than parsed as a second request.
        tunneling = true
        let channel = context.channel

        // Reading is switched off *before* the acknowledgement: whatever follows it — a TLS
        // ClientHello, or a plain request — would otherwise arrive back here, where this
        // handler is on its way out and would drop it. Disabling first leaves those bytes in
        // the socket until something that understands them exists.
        channel.setOption(ChannelOptions.autoRead, value: false).whenComplete { _ in
            self.send(context: context, bytes: Self.succeededReply)

            if let buffered = self.pending, buffered.readableBytes > 0 {
                self.handOff(context: context, bytes: buffered, engine: engine, target: target)
                return
            }

            // Nothing arrived alongside the request, so one read is accepted purely to
            // classify what comes next.
            self.sniffing = true
            channel.setOption(ChannelOptions.autoRead, value: true).whenComplete { _ in
                channel.read()
            }
        }
    }

    /// Decide what the connection actually is, then build the matching tunnel.
    ///
    /// SOCKS5 says nothing about the protocol — the client asked for `host:port` and that is
    /// all. TLS announces itself with a handshake record, so the first byte is the honest
    /// signal for whether there is anything here to decrypt. Anything else is relayed
    /// untouched rather than guessed at as HTTP.
    private func handOff(
        context: ChannelHandlerContext,
        bytes: ByteBuffer,
        engine: ProxyEngine,
        target: (host: String, port: Int)
    ) {
        let channel = context.channel

        let firstByte = bytes.getInteger(at: bytes.readerIndex, as: UInt8.self) ?? 0
        let isTLS = firstByte == Self.tlsHandshakeRecord
        let intercept = isTLS && engine.sslProxyingPolicy.shouldDecrypt(host: target.host)

        // These bytes are the start of the handshake or request, and the new pipeline needs
        // them — nothing else will deliver them. They are handed to the engine rather than
        // fired here, because the engine installs the new pipeline and resumes reading, and
        // the replay has to land before that reading does. `pending` is deliberately left in
        // place: the engine reads it at the switch, so anything that arrives while the
        // certificate is prepared goes with the rest.
        guard intercept else {
            engine.beginOpaqueTunnel(channel: channel, target: target, replay: { self.takePending() })
            return
        }

        let promise = channel.eventLoop.makePromise(of: NIOSSLContext?.self)
        Task {
            do {
                promise.succeed(try await engine.mitmContext(forHost: target.host))
            } catch {
                promise.fail(error)
            }
        }

        promise.futureResult.whenComplete { result in
            channel.eventLoop.execute {
                switch result {
                case .success(let sslContext):
                    guard let sslContext else {
                        engine.beginOpaqueTunnel(channel: channel, target: target, replay: { self.takePending() })
                        return
                    }
                    do {
                        let frontend = HTTPForwardHandler(engine: engine, tunnel: target)
                        try channel.pipeline.syncOperations.addHandler(
                            frontend,
                            name: ProxyEngine.HandlerName.frontend
                        )
                        engine.beginInterceptedTunnel(
                            channel: channel,
                            sslContext: sslContext,
                            frontend: frontend,
                            replay: { self.takePending() },
                            host: target.host
                        )
                    } catch {
                        engine.emit(.diagnostic("SOCKS5 tunnel setup failed for \(target.host): \(error)"))
                        channel.close(promise: nil)
                    }
                case .failure(let error):
                    engine.emit(.diagnostic("SOCKS5 tunnel setup failed for \(target.host): \(error)"))
                    channel.close(promise: nil)
                }
            }
        }
    }

    private func reject(context: ChannelHandlerContext, code: Reply) {
        var reply: [UInt8] = [Self.version, code.rawValue, 0x00, Self.addressIPv4]
        reply.append(contentsOf: [0, 0, 0, 0, 0, 0])
        send(context: context, bytes: reply)
        context.close(promise: nil)
    }

    private func send(context: ChannelHandlerContext, bytes: [UInt8]) {
        var buffer = context.channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        context.writeAndFlush(wrapOutboundOut(buffer), promise: nil)
    }
}
