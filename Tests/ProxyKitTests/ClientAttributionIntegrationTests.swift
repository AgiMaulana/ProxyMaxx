import XCTest
import Darwin
import Foundation
import CertKit
import ClientKit
import FlowKit
import RuleKit
@testable import ProxyKit

final class ClientAttributionIntegrationTests: XCTestCase {
    func testFastHTTPAndKeepAliveHaveIdentityOnEveryEmission() throws {
        try assertCurlAttribution(tls: false, socks: false, mapped: false)
    }

    func testMapLocalFirstTerminalEmissionAlreadyHasIdentity() throws {
        try assertCurlAttribution(tls: false, socks: false, mapped: true)
    }

    func testCONNECTRetainsIdentityAcrossKeepAliveRequests() throws {
        try assertCurlAttribution(tls: true, socks: false, mapped: false)
    }

    func testSOCKSMITMRetainsAcceptedConnectionIdentity() throws {
        try assertCurlAttribution(tls: true, socks: true, mapped: false)
    }

    func testAttributedOpaqueCONNECTStillProducesNoFlows() throws {
        try assertCurlAttribution(tls: true, socks: false, mapped: false, opaque: true)
    }

    func testAttributedOpaqueSOCKSStillProducesNoFlows() throws {
        try assertCurlAttribution(tls: true, socks: true, mapped: false, opaque: true)
    }

    func testWebSocketUpgradeAndFramesKeepAcceptedIdentity() throws {
        let authority = try CertificateAuthority(commonName: "Attribution Test CA")
        let origin = try WebSocketOriginServer()
        let originPort = try origin.start()
        defer { origin.stop() }
        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: authority
        )
        let resolver = DelayedClientResolver()
        let emissions = AttributionEmissions()
        engine.clientResolver = resolver
        engine.onEvent = { emissions.handle($0) }
        try engine.start()
        defer { engine.stop() }
        let client = try WebSocketTestClient(
            proxyPort: XCTUnwrap(engine.boundPort), originPort: originPort, caPEM: authority.certificatePEM
        )
        defer { client.close() }
        try client.upgrade()
        try client.send("attributed websocket")
        let frame = try client.receiveFrame()
        XCTAssertEqual(String(decoding: frame.payload, as: UTF8.self), "attributed websocket")
        XCTAssertTrue(emissions.wait { $0.contains { ($0.webSocketMessages?.count ?? 0) >= 2 } })
        XCTAssertFalse(emissions.snapshots.isEmpty)
        XCTAssertTrue(emissions.snapshots.allSatisfy { $0.clientApp?.pid == getpid() })
        XCTAssertEqual(resolver.callCount, 1)
    }

    private func assertCurlAttribution(tls: Bool, socks: Bool, mapped: Bool, opaque: Bool = false) throws {
        let authority = try CertificateAuthority(commonName: "Attribution Test CA")
        let leaf = try authority.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: tls, certificatePEM: leaf.certificatePEM, privateKeyPEM: leaf.privateKeyPEM,
            body: "origin-attribution"
        )
        let originPort = try origin.start()
        defer { origin.stop() }
        let scratch = FileManager.default.temporaryDirectory.appendingPathComponent("attribution-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let caURL = scratch.appendingPathComponent("ca.pem")
        try authority.certificatePEM.write(to: caURL, atomically: true, encoding: .utf8)

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: socks ? 0 : nil),
            authority: authority
        )
        let resolver = DelayedClientResolver()
        let emissions = AttributionEmissions()
        engine.clientResolver = resolver
        engine.onEvent = { emissions.handle($0) }
        if opaque { engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"]) }
        if mapped {
            let file = scratch.appendingPathComponent("response.txt")
            try "mapped-attribution".write(to: file, atomically: true, encoding: .utf8)
            engine.mapLocalRules = [MapLocalRule(
                name: "attribution", url: "/attribution", matchStyle: .contains,
                includePath: true, destination: .file(file.path)
            )]
        }
        try engine.start()
        defer { engine.stop() }

        let port = try XCTUnwrap(socks ? engine.boundSocksPort : engine.boundPort)
        let proxyArguments = socks
            ? ["--socks5-hostname", "127.0.0.1:\(port)"]
            : ["--proxy", "http://127.0.0.1:\(port)"]
        let base = "\(tls ? "https" : "http")://127.0.0.1:\(originPort)/attribution"
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = ["-sS", "--max-time", "15", "--noproxy", "", "--cacert", caURL.path]
            + proxyArguments + ["\(base)/first", "\(base)/second"]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let pid = process.processIdentifier
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let output = String(decoding: data, as: UTF8.self)
        XCTAssertEqual(process.terminationStatus, 0, output)
        let expectedBody = mapped ? "mapped-attribution" : "origin-attribution"
        XCTAssertEqual(output, expectedBody + expectedBody)
        XCTAssertEqual(resolver.callCount, 1, "both requests must share one attributed connection")

        if opaque {
            XCTAssertTrue(emissions.snapshots.isEmpty)
            return
        }
        XCTAssertTrue(emissions.wait { flows in
            Set(flows.filter { $0.timing.end != nil }.map(\.id)).count == 2
        })
        let snapshots = emissions.snapshots
        XCTAssertFalse(snapshots.isEmpty)
        XCTAssertTrue(snapshots.allSatisfy { $0.clientApp?.pid == pid }, "identity must be present before the first emission")
        XCTAssertTrue(snapshots.allSatisfy { $0.clientApp?.name == "curl" })
        XCTAssertTrue(snapshots.allSatisfy { $0.clientApp?.path == "/usr/bin/curl" })
        XCTAssertEqual(Set(snapshots.compactMap(\.clientAddress)).count, 1)
        let terminal = snapshots.filter { $0.timing.end != nil }
        XCTAssertEqual(terminal.count, 2, "attribution must not re-emit a completed flow")
        XCTAssertTrue(terminal.allSatisfy { $0.isIntercepted == tls })
        XCTAssertTrue(terminal.allSatisfy { $0.isMappedLocally == mapped })
    }
}

private final class DelayedClientResolver: ClientAppResolving, @unchecked Sendable {
    private let resolver = ClientAppResolver()
    private let lock = NSLock()
    private var calls = 0

    var callCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return calls
    }

    func resolveClientApp(
        clientAddress: String, clientPort: Int, proxyAddress: String, proxyPort: Int,
        completion: @escaping @Sendable (ClientApp?) -> Void
    ) {
        lock.lock()
        calls += 1
        lock.unlock()
        DispatchQueue.global().asyncAfter(deadline: .now() + .milliseconds(150)) { [self] in
            resolver.resolveClientApp(
                clientAddress: clientAddress, clientPort: clientPort,
                proxyAddress: proxyAddress, proxyPort: proxyPort, completion: completion
            )
        }
    }
}

private final class AttributionEmissions: @unchecked Sendable {
    private let condition = NSCondition()
    private var flows: [Flow] = []

    var snapshots: [Flow] {
        condition.lock()
        defer { condition.unlock() }
        return flows
    }

    func handle(_ event: ProxyEvent) {
        guard case .flow(let flow) = event else { return }
        condition.lock()
        flows.append(flow)
        condition.broadcast()
        condition.unlock()
    }

    func wait(until predicate: ([Flow]) -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(5)
        condition.lock()
        defer { condition.unlock() }
        while !predicate(flows) {
            if !condition.wait(until: deadline) { return predicate(flows) }
        }
        return true
    }
}
