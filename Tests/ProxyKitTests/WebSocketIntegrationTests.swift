import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOSSL
@testable import ProxyKit
import CertKit
import FlowKit

/// End-to-end WebSocket test: the client tunnels through the proxy with `CONNECT`,
/// completes the TLS handshake, upgrades, and exchanges a frame both ways.
final class WebSocketIntegrationTests: XCTestCase {
    func testWebSocketFramesAreRelayedAndRecorded() throws {
        try assertEcho(greeting: nil)
    }

    /// The server often puts the first frame in the same packet as the `101`. The
    /// response decoder has already buffered those bytes when the relay is installed,
    /// so this exercises the leftover hand-off rather than a later socket read.
    func testFrameSentWithTheHandshakeIsNotLost() throws {
        try assertEcho(greeting: "welcome")
    }

    private func assertEcho(greeting: String?) throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let origin = try WebSocketOriginServer(greeting: greeting)
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: ca
        )
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let client = try WebSocketTestClient(proxyPort: engine.boundPort!, originPort: originPort, caPEM: ca.certificatePEM)
        defer { client.close() }

        try client.upgrade()
        if let greeting {
            let first = try client.receiveFrame()
            XCTAssertEqual(String(decoding: first.payload, as: UTF8.self), greeting)
        }

        try client.send("hello websocket")
        let echo = try client.receiveFrame()
        XCTAssertEqual(String(decoding: echo.payload, as: UTF8.self), "hello websocket")

        let flow = try XCTUnwrap(waitForFlow(in: collector, statusCode: 101, timeout: 5))
        XCTAssertEqual(flow.request.headers["Upgrade"], "websocket")
        XCTAssertEqual(flow.isIntercepted, true)

        let messages = try XCTUnwrap(flow.webSocketMessages)
        let expectedCount = greeting == nil ? 2 : 3
        XCTAssertEqual(messages.count, expectedCount)
        if greeting != nil {
            XCTAssertEqual(messages[0].direction, .serverToClient)
            XCTAssertEqual(String(decoding: messages[0].payload, as: UTF8.self), greeting)
        }
        let sent = greeting == nil ? messages[0] : messages[1]
        let received = greeting == nil ? messages[1] : messages[2]
        XCTAssertEqual(sent.direction, .clientToServer)
        XCTAssertEqual(sent.opcode, "text")
        XCTAssertEqual(String(decoding: sent.payload, as: UTF8.self), "hello websocket")
        XCTAssertEqual(received.direction, .serverToClient)
        XCTAssertEqual(String(decoding: received.payload, as: UTF8.self), "hello websocket")
    }

    private func waitForFlow(in collector: FlowCollector, statusCode: Int, timeout: TimeInterval) -> Flow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flow = collector.all.first(where: { $0.statusCode == statusCode }) {
                return flow
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}

// MARK: - Origin

/// A TLS origin that answers the opening handshake and echoes each text frame.
final class WebSocketOriginServer {
    private let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
    private var channel: Channel?
    private let tlsContext: NIOSSLContext
    private let greeting: String?

    init(greeting: String? = nil) throws {
        self.greeting = greeting
        let ca = try CertificateAuthority(commonName: "WebSocket Origin CA")
        let leaf = try ca.makeLeafCertificate(forHost: "127.0.0.1")
        let certificates = try NIOSSLCertificate.fromPEMBytes(Array(leaf.certificatePEM.utf8))
        let key = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
        var configuration = TLSConfiguration.makeServerConfiguration(
            certificateChain: certificates.map { .certificate($0) },
            privateKey: .privateKey(key)
        )
        configuration.minimumTLSVersion = .tlsv12
        self.tlsContext = try NIOSSLContext(configuration: configuration)
    }

    func start() throws -> Int {
        let tlsContext = self.tlsContext
        let greeting = self.greeting
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(NIOSSLServerHandler(context: tlsContext), position: .first)
                    .flatMap { channel.pipeline.addHandler(WebSocketOriginHandler(greeting: greeting)) }
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

private final class WebSocketOriginHandler: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer
    typealias OutboundOut = ByteBuffer

    private let greeting: String?
    private var handshake = Data()
    private var hasUpgraded = false
    private var parser = WebSocketFrameParser()

    init(greeting: String?) {
        self.greeting = greeting
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let buffer = unwrapInboundIn(data)

        guard hasUpgraded else {
            handshake.append(contentsOf: buffer.readableBytesView)
            let terminator = Data("\r\n\r\n".utf8)
            guard let range = handshake.range(of: terminator) else { return }

            hasUpgraded = true
            let remainder = handshake[range.upperBound...]
            handshake.removeAll()

            var head = context.channel.allocator.buffer(capacity: 160)
            head.writeString(
                "HTTP/1.1 101 Switching Protocols\r\n"
                    + "Upgrade: websocket\r\n"
                    + "Connection: Upgrade\r\n"
                    + "Sec-WebSocket-Accept: test\r\n\r\n"
            )
            if let greeting {
                appendFrame(opcode: 0x1, payload: Data(greeting.utf8), to: &head)
            }
            context.writeAndFlush(wrapOutboundOut(head), promise: nil)

            if !remainder.isEmpty {
                echo(Data(remainder), context: context)
            }
            return
        }

        echo(Data(buffer.readableBytesView), context: context)
    }

    private func echo(_ bytes: Data, context: ChannelHandlerContext) {
        var input = context.channel.allocator.buffer(capacity: bytes.count)
        input.writeBytes(bytes)
        for frame in parser.consume(input) where frame.opcode == 0x1 || frame.opcode == 0x2 {
            var output = context.channel.allocator.buffer(capacity: frame.payload.count + 4)
            appendFrame(opcode: frame.opcode, payload: frame.payload, to: &output)
            context.writeAndFlush(wrapOutboundOut(output), promise: nil)
        }
    }

    private func appendFrame(opcode: UInt8, payload: Data, to buffer: inout ByteBuffer) {
        buffer.writeInteger(UInt8(0x80 | opcode))
        if payload.count < 126 {
            buffer.writeInteger(UInt8(payload.count))
        } else {
            buffer.writeInteger(UInt8(126))
            buffer.writeInteger(UInt16(payload.count), endianness: .big)
        }
        buffer.writeBytes(payload)
    }
}

// MARK: - Client

/// Speaks raw WebSocket over a `CONNECT` tunnel so the test drives the same path a
/// browser or desktop app does, without depending on an external client binary.
final class WebSocketTestClient {
    private let group: MultiThreadedEventLoopGroup
    private let channel: Channel
    private let inbox: ByteInbox
    private let originPort: Int

    init(proxyPort: Int, originPort: Int, caPEM: String) throws {
        self.originPort = originPort
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        self.inbox = ByteInbox()
        self.channel = try ClientBootstrap(group: group)
            .connect(host: "127.0.0.1", port: proxyPort)
            .wait()
        try channel.pipeline.addHandler(inbox).wait()

        let connect = "CONNECT 127.0.0.1:\(originPort) HTTP/1.1\r\nHost: 127.0.0.1:\(originPort)\r\n\r\n"
        try write(Array(connect.utf8))
        let response = try inbox.read(until: Data("\r\n\r\n".utf8))
        guard String(decoding: response, as: UTF8.self).contains(" 200 ") else {
            throw WebSocketTestError("CONNECT failed: \(String(decoding: response, as: UTF8.self))")
        }

        var tls = TLSConfiguration.makeClientConfiguration()
        tls.certificateVerification = .fullVerification
        tls.trustRoots = .certificates(try NIOSSLCertificate.fromPEMBytes(Array(caPEM.utf8)))
        let context = try NIOSSLContext(configuration: tls)
        // The proxy omits SNI for IP literals, so the test client must too. Chain
        // verification still runs against the proxy CA supplied above.
        try channel.pipeline.addHandler(
            NIOSSLClientHandler(context: context, serverHostname: nil),
            position: .first
        ).wait()
    }

    /// Send the upgrade request and require a `101`.
    func upgrade() throws {
        let request = "GET /ws HTTP/1.1\r\n"
            + "Host: 127.0.0.1:\(originPort)\r\n"
            + "Upgrade: websocket\r\n"
            + "Connection: Upgrade\r\n"
            + "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\n"
            + "Sec-WebSocket-Version: 13\r\n\r\n"
        try write(Array(request.utf8))

        let head = try inbox.read(until: Data("\r\n\r\n".utf8))
        guard String(decoding: head, as: UTF8.self).contains(" 101 ") else {
            throw WebSocketTestError("upgrade failed: \(String(decoding: head, as: UTF8.self))")
        }
    }

    func send(_ message: String) throws {
        try write(clientFrame(opcode: 0x1, payload: Array(message.utf8)))
    }

    func receiveFrame() throws -> (opcode: UInt8, payload: Data) {
        let header = try inbox.readBytes(count: 2)
        let opcode = header[header.startIndex] & 0x0F
        var length = Int(header[header.startIndex + 1] & 0x7F)

        if length == 126 {
            let extended = try inbox.readBytes(count: 2)
            length = Int(extended[extended.startIndex]) << 8 | Int(extended[extended.startIndex + 1])
        } else if length == 127 {
            let extended = try inbox.readBytes(count: 8)
            var value: UInt64 = 0
            for byte in extended { value = (value << 8) | UInt64(byte) }
            length = Int(value)
        }

        return (opcode, try inbox.readBytes(count: length))
    }

    func close() {
        try? channel.close().wait()
        try? group.syncShutdownGracefully()
    }

    private func write(_ bytes: [UInt8]) throws {
        var buffer = channel.allocator.buffer(capacity: bytes.count)
        buffer.writeBytes(bytes)
        try channel.writeAndFlush(buffer).wait()
    }

    private func clientFrame(opcode: UInt8, payload: [UInt8]) -> [UInt8] {
        var bytes: [UInt8] = [0x80 | opcode, 0x80 | UInt8(payload.count)]
        let key: [UInt8] = [0x37, 0xFA, 0x21, 0x3D]
        bytes.append(contentsOf: key)
        bytes.append(contentsOf: payload.enumerated().map { $0.element ^ key[$0.offset % 4] })
        return bytes
    }
}

struct WebSocketTestError: Error, CustomStringConvertible {
    let description: String
    init(_ description: String) { self.description = description }
}

/// Buffers inbound bytes and lets the test thread await a marker or a byte count.
final class ByteInbox: ChannelInboundHandler {
    typealias InboundIn = ByteBuffer

    private final class Waiter {
        enum Kind {
            case until(Data)
            case count(Int)
        }
        let kind: Kind
        let promise: EventLoopPromise<Data>
        var done = false

        init(kind: Kind, promise: EventLoopPromise<Data>) {
            self.kind = kind
            self.promise = promise
        }
    }

    private let lock = NSLock()
    private var buffer = Data()
    private var waiters: [Waiter] = []
    private var eventLoop: EventLoop?

    func handlerAdded(context: ChannelHandlerContext) {
        eventLoop = context.eventLoop
    }

    func read(until marker: Data, timeout: TimeInterval = 5) throws -> Data {
        try read(kind: .until(marker), timeout: timeout)
    }

    func readBytes(count: Int, timeout: TimeInterval = 5) throws -> Data {
        try read(kind: .count(count), timeout: timeout)
    }

    private func read(kind: Waiter.Kind, timeout: TimeInterval) throws -> Data {
        guard let loop = eventLoop else { throw WebSocketTestError("inbox is not installed") }

        lock.lock()
        if let value = take(kind: kind) {
            lock.unlock()
            return value
        }
        let promise = loop.makePromise(of: Data.self)
        let waiter = Waiter(kind: kind, promise: promise)
        waiters.append(waiter)
        lock.unlock()

        loop.scheduleTask(in: .milliseconds(Int64(timeout * 1000))) {
            self.lock.lock()
            let pending = !waiter.done
            waiter.done = true
            self.lock.unlock()
            if pending {
                promise.fail(WebSocketTestError("timed out waiting for bytes"))
            }
        }
        return try promise.futureResult.wait()
    }

    /// Remove and return the requested slice, if the buffer already holds it.
    /// Caller holds the lock.
    private func take(kind: Waiter.Kind) -> Data? {
        switch kind {
        case .until(let marker):
            guard let range = buffer.range(of: marker) else { return nil }
            let value = Data(buffer[..<range.upperBound])
            buffer.removeSubrange(..<range.upperBound)
            return value
        case .count(let count):
            guard buffer.count >= count else { return nil }
            let value = Data(buffer.prefix(count))
            buffer.removeFirst(count)
            return value
        }
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        let bytes = Data(unwrapInboundIn(data).readableBytesView)
        lock.lock()
        buffer.append(bytes)
        var completed: [(Waiter, Data)] = []
        var remaining: [Waiter] = []
        for waiter in waiters where !waiter.done {
            if let value = take(kind: waiter.kind) {
                waiter.done = true
                completed.append((waiter, value))
            } else {
                remaining.append(waiter)
            }
        }
        waiters = remaining
        lock.unlock()
        for (waiter, value) in completed {
            waiter.promise.succeed(value)
        }
    }

    func channelInactive(context: ChannelHandlerContext) {
        lock.lock()
        let pending = waiters
        waiters.removeAll()
        for waiter in pending { waiter.done = true }
        lock.unlock()
        for waiter in pending {
            waiter.promise.fail(WebSocketTestError("connection closed"))
        }
    }
}
