import XCTest
import Foundation
@testable import ProxyKit
import CertKit
import FlowKit
import RuleKit

/// End-to-end Map Local tests: a real `curl` client, a real origin server, and a real
/// local file answering instead of it.
final class MapLocalIntegrationTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory.appendingPathComponent("maplocal-it-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    // MARK: - Plain HTTP

    func testPlainHTTPIsServedFromALocalFile() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let mapped = try writeFile("from-local", name: "mapped.txt")
        plain.engine.mapLocalRules = [pathRule("/mapped", destination: .file(mapped.path))]

        let result = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "from-local")

        let flow = try XCTUnwrap(plain.collector.waitForCompletedFlow(timeout: 5))
        XCTAssertEqual(flow.response?.statusCode, 200)
        XCTAssertTrue(flow.isMappedLocally, "the flow should record that it was answered locally")
        XCTAssertEqual(flow.localMapSource, "Local File: \(mapped.path)")
    }

    func testNonMatchingPathFallsThroughToTheOrigin() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let mapped = try writeFile("from-local", name: "mapped.txt")
        plain.engine.mapLocalRules = [pathRule("/mapped", destination: .file(mapped.path))]

        let result = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/other")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "from-origin")

        let flow = try XCTUnwrap(plain.collector.waitForCompletedFlow(timeout: 5))
        XCTAssertFalse(flow.isMappedLocally)
        XCTAssertNil(flow.localMapSource)
    }

    func testMissingMappedFileFallsThroughToTheOrigin() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let missing = scratch.appendingPathComponent("does-not-exist.json")
        plain.engine.mapLocalRules = [pathRule("/mapped", name: "gone", destination: .file(missing.path))]

        let result = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "from-origin", "a rule whose file is gone must not block the request")

        let flow = try XCTUnwrap(plain.collector.waitForCompletedFlow(timeout: 5))
        XCTAssertFalse(flow.isMappedLocally)
        XCTAssertTrue(plain.collector.diagnostics.contains { $0.contains("gone") }, "the skipped rule should be reported")
    }

    func testFirstMatchingRuleWins() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let first = try writeFile("first", name: "first.txt")
        let second = try writeFile("second", name: "second.txt")
        plain.engine.mapLocalRules = [
            pathRule("/mapped", name: "first", destination: .file(first.path)),
            pathRule("/mapped", name: "second", destination: .file(second.path)),
        ]

        let result = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        XCTAssertEqual(result.output, "first")
    }

    func testScenarioActivationChangesTheResponseServedByTheProxy() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let visitFile = try writeFile("visit", name: "visit.txt")
        let emptyCartFile = try writeFile("empty-cart", name: "empty-cart.txt")
        var rules = [
            pathRule("/mapped", name: "consult-ok", destination: .file(visitFile.path)),
            pathRule("/mapped", name: "consult-empty", destination: .file(emptyCartFile.path)),
        ]
        let visit = MapLocalScenario(name: "visit", ruleIDs: [rules[0].id])
        let emptyCart = MapLocalScenario(name: "empty-cart", ruleIDs: [rules[1].id])

        XCTAssertEqual(MapLocalScenarioRunner.activate(visit, in: &rules), 1)
        plain.engine.mapLocalRules = rules
        let visitResult = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        XCTAssertEqual(visitResult.output, "visit")
        XCTAssertEqual(rules.map(\.isEnabled), [true, false])

        XCTAssertEqual(MapLocalScenarioRunner.activate(emptyCart, in: &rules), 1)
        plain.engine.mapLocalRules = rules
        let emptyCartResult = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        XCTAssertEqual(emptyCartResult.output, "empty-cart")
        XCTAssertEqual(rules.map(\.isEnabled), [false, true])
    }

    func testFullHTTPMessageFileIsServedWithItsStatusAndHeaders() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let message = "HTTP/1.1 503 Service Unavailable\r\nContent-Type: text/plain\r\nX-Mapped: yes\r\n\r\nmaintenance"
        let file = try writeFile(message, name: "message.txt")
        plain.engine.mapLocalRules = [pathRule("/mapped", destination: .file(file.path))]

        let result = try curlThroughProxy(
            plain.engine,
            url: "http://127.0.0.1:\(plain.port)/mapped",
            extraArguments: ["-i"]
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("503"), result.output)
        XCTAssertTrue(result.output.contains("X-Mapped: yes"), result.output)
        XCTAssertTrue(result.output.hasSuffix("maintenance"), result.output)

        let flow = try XCTUnwrap(plain.collector.waitForCompletedFlow(timeout: 5))
        XCTAssertEqual(flow.response?.statusCode, 503)
    }

    func testResponseDelayHoldsTheWriteBack() throws {
        let plain = try startPlainProxy(originBody: "from-origin")
        defer { plain.stop() }

        let mapped = try writeFile("slow", name: "slow.txt")
        var delayed = pathRule("/mapped", destination: .file(mapped.path))
        delayed.responseDelay = 0.4
        plain.engine.mapLocalRules = [delayed]

        let started = Date()
        let result = try curlThroughProxy(plain.engine, url: "http://127.0.0.1:\(plain.port)/mapped")
        let elapsed = Date().timeIntervalSince(started)
        XCTAssertEqual(result.output, "slow")
        XCTAssertGreaterThanOrEqual(elapsed, 0.35, "the configured delay should hold the response back")
    }

    // MARK: - HTTPS

    func testHTTPSRequestIsServedFromALocalDirectory() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "from-origin"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        _ = try writeFile("{\"mock\":true}", name: "v1/mock.json")
        let caURL = try writeFile(ca.certificatePEM, name: "ca.pem")

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        let collector = MapLocalCollector()
        engine.onEvent = { collector.handle($0) }
        engine.mapLocalRules = [pathRule("/v1/mock.json", destination: .directory(scratch.path))]
        try engine.start()
        defer { engine.stop() }

        let result = try curlThroughProxy(
            engine,
            url: "https://127.0.0.1:\(originPort)/v1/mock.json",
            caURL: caURL
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"mock\":true}")

        let flow = try XCTUnwrap(collector.waitForCompletedFlow(timeout: 5))
        XCTAssertEqual(flow.response?.headers["Content-Type"], "application/json")
        XCTAssertTrue(flow.isMappedLocally)
    }

    /// A host excluded from SSL Proxying is relayed opaquely, so its request is never
    /// visible to Map Local and the mapping cannot apply.
    func testExcludedHostIsNotMapped() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: "from-origin"
        )
        let originPort = try origin.start()
        defer { origin.stop() }

        let mapped = try writeFile("from-local", name: "mapped.txt")
        let originCAURL = try writeFile(originCA.certificatePEM, name: "origin-ca.pem")

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"])
        let collector = MapLocalCollector()
        engine.onEvent = { collector.handle($0) }
        engine.mapLocalRules = [hostRule("127.0.0.1", destination: .file(mapped.path))]
        try engine.start()
        defer { engine.stop() }

        let result = try curlThroughProxy(
            engine,
            url: "https://127.0.0.1:\(originPort)/mapped",
            caURL: originCAURL
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "from-origin", "an opaque tunnel is not rewritten")
        XCTAssertFalse(collector.all.contains { $0.isMappedLocally })
    }

    // MARK: - Fixtures

    private struct PlainProxy {
        let engine: ProxyEngine
        let origin: OriginServer
        let port: Int
        let collector: MapLocalCollector

        func stop() {
            engine.stop()
            origin.stop()
        }
    }

    private func startPlainProxy(originBody: String) throws -> PlainProxy {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let origin = try OriginServer(tls: false, body: originBody)
        let port = try origin.start()

        let engine = try ProxyEngine(configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil), authority: ca)
        let collector = MapLocalCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        return PlainProxy(engine: engine, origin: origin, port: port, collector: collector)
    }

    /// Match a path fragment anywhere in the URL, which covers the ephemeral test port.
    private func pathRule(_ path: String, name: String = "rule", destination: MapLocalDestination) -> MapLocalRule {
        MapLocalRule(name: name, url: path, matchStyle: .contains, includePath: true, destination: destination)
    }

    /// Match the host alone, ignoring the path.
    private func hostRule(_ host: String, name: String = "rule", destination: MapLocalDestination) -> MapLocalRule {
        MapLocalRule(name: name, url: host, matchStyle: .contains, includePath: false, destination: destination)
    }

    @discardableResult
    private func writeFile(_ text: String, name: String) throws -> URL {
        let url = scratch.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    // MARK: - curl

    private struct CurlResult {
        let status: Int32
        let output: String
    }

    private func curlThroughProxy(
        _ engine: ProxyEngine,
        url: String,
        caURL: URL? = nil,
        extraArguments: [String] = []
    ) throws -> CurlResult {
        var arguments = [
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
        ]
        if let caURL {
            arguments.append(contentsOf: ["--cacert", caURL.path])
        }
        arguments.append(contentsOf: extraArguments)
        arguments.append(url)

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

/// Collects flows and diagnostics emitted by the engine.
final class MapLocalCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var flows: [UUID: Flow] = [:]
    private var order: [UUID] = []
    private var recordedDiagnostics: [String] = []

    func handle(_ event: ProxyEvent) {
        lock.lock(); defer { lock.unlock() }
        switch event {
        case .flow(let flow):
            if flows[flow.id] == nil { order.append(flow.id) }
            flows[flow.id] = flow
        case .diagnostic(let message):
            recordedDiagnostics.append(message)
        case .stateChanged:
            break
        }
    }

    var all: [Flow] {
        lock.lock(); defer { lock.unlock() }
        return order.compactMap { flows[$0] }
    }

    var diagnostics: [String] {
        lock.lock(); defer { lock.unlock() }
        return recordedDiagnostics
    }

    func waitForCompletedFlow(timeout: TimeInterval) -> Flow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let flow = all.first(where: { $0.response != nil }) { return flow }
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}
