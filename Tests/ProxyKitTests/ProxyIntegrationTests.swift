import XCTest
import Foundation
@testable import ProxyKit
import CertKit
import FlowKit
import RuleKit

/// End-to-end tests that drive the proxy with the system `curl` binary.
final class ProxyIntegrationTests: XCTestCase {
    func testPlainHTTPIsForwardedAndRecorded() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let origin = try OriginServer(tls: false, body: "{\"plain\":true}")
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "http://127.0.0.1:\(originPort)/plain",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"plain\":true}")

        let flow = collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow, "the proxy should have recorded a completed flow")
        XCTAssertEqual(flow?.response?.statusCode, 200)
        XCTAssertEqual(flow?.request.method, "GET")
        XCTAssertEqual(flow?.isIntercepted, false)
        XCTAssertEqual(flow?.response?.body, Data("{\"plain\":true}".utf8))
    }

    func testHTTPSIsInterceptedAndDecrypted() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "{\"hello\":\"world\"}"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let caURL = FileManager.default.temporaryDirectory.appendingPathComponent("proxymaxx-test-\(UUID().uuidString).pem")
        try ca.certificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: caURL) }

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "--cacert", caURL.path,
            "https://127.0.0.1:\(originPort)/hello",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"hello\":\"world\"}")

        let flow = collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow, "the proxy should have recorded a decrypted flow")
        XCTAssertEqual(flow?.response?.statusCode, 200)
        XCTAssertEqual(flow?.isIntercepted, true, "HTTPS flow should be marked intercepted")
        XCTAssertEqual(flow?.request.host, "127.0.0.1")
        XCTAssertEqual(flow?.response?.body, Data("{\"hello\":\"world\"}".utf8))
    }

    /// A host excluded from SSL Proxying must be relayed byte-for-byte: the client's TLS
    /// runs end to end to the origin, and the proxy records no decrypted flow.
    func testExcludedHostIsTunneledOpaquely() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "opaque-ok"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"])
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let originCAURL = FileManager.default.temporaryDirectory.appendingPathComponent("proxymaxx-origin-\(UUID().uuidString).pem")
        try originCA.certificatePEM.write(to: originCAURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: originCAURL) }

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "--cacert", originCAURL.path,
            "https://127.0.0.1:\(originPort)/opaque",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "opaque-ok")
        XCTAssertTrue(collector.all.isEmpty, "an excluded host must not produce a decrypted flow")
    }

    /// Serves the same leaf certificate the proxy would present, but directly,
    /// to isolate TLS configuration from the CONNECT pipeline swap.
    func testLeafCertificateServesTLS() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let leaf = try ca.makeLeafCertificate(forHost: "127.0.0.1")
        let server = try OriginServer(tls: true, certificatePEM: leaf.certificatePEM, privateKeyPEM: leaf.privateKeyPEM, body: "ok")
        let port = try server.start()
        defer { server.stop() }

        let caURL = FileManager.default.temporaryDirectory.appendingPathComponent("proxymaxx-leaf-\(UUID().uuidString).pem")
        try ca.certificatePEM.write(to: caURL, atomically: true, encoding: .utf8)
        defer { try? FileManager.default.removeItem(at: caURL) }

        let result = try runCurl(["-sS", "--max-time", "10", "--cacert", caURL.path, "https://127.0.0.1:\(port)/"])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "ok")
    }

    // MARK: - Helpers

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

/// Thread-safe accumulator for flows emitted by the engine.
final class FlowCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var flows: [UUID: Flow] = [:]
    private var order: [UUID] = []

    func handle(_ event: ProxyEvent) {
        guard case .flow(let flow) = event else { return }
        lock.lock()
        if flows[flow.id] == nil { order.append(flow.id) }
        flows[flow.id] = flow
        lock.unlock()
    }

    var all: [Flow] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { flows[$0] }
    }

    func waitForCompletedFlow(timeout: TimeInterval) -> Flow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flow = all.first(where: { $0.response != nil }) {
                return flow
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}
