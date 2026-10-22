import XCTest
import Foundation
import Darwin
@testable import ProxyKit
import CertKit
import FlowKit
import RuleKit

/// End-to-end tests for the SOCKS5 listener the Android tunnel talks to.
///
/// Driven with `curl --socks5-hostname`, which is the closest thing to the tunnel's own
/// behaviour: the proxy — not the client — is what resolves the destination.
final class SOCKS5IntegrationTests: XCTestCase {

    func testSOCKS5CarriesHTTPSThroughAndDecryptsIt() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "{\"socks\":true}"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: 0),
            authority: ca
        )
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let socksPort = try XCTUnwrap(engine.boundSocksPort, "the SOCKS5 listener should have bound a port")
        let caURL = try write(ca.certificatePEM)

        let diagnostics = Diagnostics()
        engine.onEvent = { event in
            collector.handle(event)
            diagnostics.handle(event)
        }

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--socks5-hostname", "127.0.0.1:\(socksPort)",
            "--cacert", caURL.path,
            "https://127.0.0.1:\(originPort)/socks",
        ])
        XCTAssertEqual(result.status, 0, result.output + "\n" + diagnostics.report())
        XCTAssertEqual(result.output, "{\"socks\":true}")

        let flow = collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow, "a SOCKS5 connection should be recorded like any other")
        XCTAssertEqual(flow?.response?.statusCode, 200)
        XCTAssertEqual(flow?.isIntercepted, true, "the leaf for the target should have been presented")
        XCTAssertEqual(flow?.request.host, "127.0.0.1")
        XCTAssertEqual(flow?.response?.body, Data("{\"socks\":true}".utf8))
    }

    /// A host excluded from SSL Proxying must be relayed untouched through SOCKS5 too.
    func testSOCKS5HonoursTheExcludeList() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "opaque-socks"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: 0),
            authority: ca
        )
        engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"])
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let socksPort = try XCTUnwrap(engine.boundSocksPort)
        let originCAURL = try write(originCA.certificatePEM)

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--socks5-hostname", "127.0.0.1:\(socksPort)",
            "--cacert", originCAURL.path,
            "https://127.0.0.1:\(originPort)/opaque",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "opaque-socks")
        XCTAssertTrue(collector.all.isEmpty, "an excluded host must not be decrypted")
    }

    // MARK: - Protocol

    func testRefusesMethodsItCannotServe() throws {
        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        // Version 5, one method offered: username/password (0x02).
        connection.send([0x05, 0x01, 0x02])
        XCTAssertEqual(connection.receive(2), [0x05, 0xFF])
    }

    func testReportsAnUnsupportedCommand() throws {
        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        connection.send([0x05, 0x01, 0x00])
        XCTAssertEqual(connection.receive(2), [0x05, 0x00])

        // BIND (0x02) is valid SOCKS5 but not something a debugging proxy serves.
        connection.send([0x05, 0x02, 0x00, 0x01, 127, 0, 0, 1, 0, 80])
        let reply = connection.receive(4)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x07, "expected 'command not supported'")
    }

    func testReportsAnUnsupportedAddressType() throws {
        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        connection.send([0x05, 0x01, 0x00])
        XCTAssertEqual(connection.receive(2), [0x05, 0x00])

        connection.send([0x05, 0x01, 0x00, 0x05]) // 0x05 is not a SOCKS5 address type
        let reply = connection.receive(4)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x08, "expected 'address type not supported'")
    }

    func testAcceptsADomainNameAndAcknowledges() throws {
        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        connection.send([0x05, 0x01, 0x00])
        XCTAssertEqual(connection.receive(2), [0x05, 0x00])

        let name = Array("localhost".utf8)
        connection.send([0x05, 0x01, 0x00, 0x03, UInt8(name.count)] + name + [0x1F, 0x90])
        let reply = connection.receive(10)
        XCTAssertEqual(reply[0], 0x05)
        XCTAssertEqual(reply[1], 0x00, "expected success")
    }

    /// SOCKS5 says nothing about the protocol, so a connection that is not TLS must be
    /// relayed rather than assumed to be HTTPS and broken. This is the port-80 case.
    func testPlainHTTPOverSOCKS5IsRelayedNotDecrypted() throws {
        let origin = try OriginServer(tls: false, body: "plain-socks", contentType: "text/plain")
        let originPort = try origin.start()
        defer { origin.stop() }

        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        connection.send([0x05, 0x01, 0x00])
        XCTAssertEqual(connection.receive(2), [0x05, 0x00])

        connection.send([
            0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1,
            UInt8((originPort >> 8) & 0xFF), UInt8(originPort & 0xFF),
        ])
        XCTAssertEqual(connection.receive(10)[1], 0x00, "expected the CONNECT to be accepted")

        connection.send(Array("GET /plain HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8))
        let response = connection.receiveUntil("plain-socks")
        XCTAssertTrue(response.contains("plain-socks"), "expected the origin body, got: \(response)")
    }

    /// SOCKS5 gives no protocol signal, so the first bytes are read to classify the
    /// connection and then handed to whatever pipeline replaces the handshake. They have to
    /// reach it *before* reading resumes: relayed in pieces, a request can otherwise be
    /// reassembled out of order. This is the shape of traffic from an emulator's tunnel,
    /// which delivers TCP segments rather than one tidy write.
    func testRequestDeliveredInPiecesOverSOCKS5IsReassembled() throws {
        let origin = try OriginServer(tls: false, body: "split-request", contentType: "text/plain")
        let originPort = try origin.start()
        defer { origin.stop() }

        let (engine, port) = try listeningEngine()
        defer { engine.stop() }

        let connection = try RawConnection(port: port)
        defer { connection.close() }
        connection.send([0x05, 0x01, 0x00])
        XCTAssertEqual(connection.receive(2), [0x05, 0x00])

        connection.send([
            0x05, 0x01, 0x00, 0x01, 127, 0, 0, 1,
            UInt8((originPort >> 8) & 0xFF), UInt8(originPort & 0xFF),
        ])
        XCTAssertEqual(connection.receive(10)[1], 0x00, "expected the CONNECT to be accepted")

        // Split mid-method, so the classification byte and the rest of the request land in
        // separate reads.
        let request = Array("GET /split HTTP/1.1\r\nHost: 127.0.0.1\r\n\r\n".utf8)
        connection.send(Array(request.prefix(9)))
        usleep(60_000)
        connection.send(Array(request.dropFirst(9)))

        let response = connection.receiveUntil("split-request")
        XCTAssertTrue(response.contains("split-request"), "expected the origin body, got: \(response)")
    }

    // MARK: - Helpers

    /// An engine whose SOCKS5 port is chosen by the OS, so tests never collide with a real
    /// ProxyMaxx on 8989.
    private func listeningEngine() throws -> (ProxyEngine, Int) {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: 0),
            authority: ca
        )
        try engine.start()
        return (engine, try XCTUnwrap(engine.boundSocksPort))
    }

    private func write(_ pem: String) throws -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxymaxx-socks-\(UUID().uuidString).pem")
        try pem.write(to: url, atomically: true, encoding: .utf8)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }

    private struct CurlResult {
        let status: Int32
        let output: String
    }

    private func runCurl(_ arguments: [String]) throws -> CurlResult {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return CurlResult(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }
}

/// Records the engine's own diagnostics, so a failure explains itself.
private final class Diagnostics: @unchecked Sendable {
    private let lock = NSLock()
    private var messages: [String] = []

    func handle(_ event: ProxyEvent) {
        guard case .diagnostic(let message) = event else { return }
        lock.lock()
        messages.append(message)
        lock.unlock()
    }

    func report() -> String {
        lock.lock(); defer { lock.unlock() }
        return messages.isEmpty ? "(no diagnostics)" : messages.joined(separator: "\n")
    }
}

/// A bare TCP connection, so the handshake can be asserted byte by byte.
private final class RawConnection {
    private let descriptor: Int32

    init(port: Int) throws {
        descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(.ENFILE) }

        var timeout = timeval(tv_sec: 2, tv_usec: 0)
        setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let connected = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        guard connected == 0 else {
            Darwin.close(descriptor)
            throw POSIXError(.ECONNREFUSED)
        }
    }

    func send(_ bytes: [UInt8]) {
        _ = bytes.withUnsafeBufferPointer { write(descriptor, $0.baseAddress, $0.count) }
    }

    func receive(_ count: Int) -> [UInt8] {
        var buffer = [UInt8](repeating: 0, count: count)
        var read = 0
        while read < count {
            let chunk = buffer.withUnsafeMutableBytes { pointer in
                recv(descriptor, pointer.baseAddress!.advanced(by: read), count - read, 0)
            }
            guard chunk > 0 else { break }
            read += chunk
        }
        return Array(buffer.prefix(read))
    }

    /// Read until `marker` appears, so a relayed response can be checked without waiting for
    /// a close the origin never sends.
    func receiveUntil(_ marker: String, attempts: Int = 8) -> String {
        var collected = Data()
        for _ in 0..<attempts {
            let chunk = receive(4096)
            if chunk.isEmpty { break }
            collected.append(contentsOf: chunk)
            if String(decoding: collected, as: UTF8.self).contains(marker) { break }
        }
        return String(decoding: collected, as: UTF8.self)
    }

    func close() {
        Darwin.close(descriptor)
    }
}
