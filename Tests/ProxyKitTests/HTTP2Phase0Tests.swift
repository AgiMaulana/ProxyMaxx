import XCTest
import Foundation
@testable import ProxyKit
import CertKit
import FlowKit
import RuleKit

/// HTTP/2 Phase 0 fixtures (#79): pin what the proxy does with HTTP/2 traffic *today*,
/// before any ALPN or frame-parsing change lands, so every later phase has a recorded
/// baseline to defend and to flip.
///
/// The matrix mirrors #85's scope table. Every "fails today" assertion is a documented
/// gap, not a desired outcome — Phase 1 (`ALPN plumbing`) and Phase 3 (decode-only MITM)
/// are expected to flip them.
final class HTTP2Phase0Tests: XCTestCase {
    // MARK: - MITM on, client offers h2, origin is HTTP/1.1

    /// `curl --http2` offers ALPN `h2, http/1.1` inside the tunnel. The MITM side does
    /// not advertise any ALPN, so curl falls back to HTTP/1.1 and the flow is tagged
    /// accordingly. This is the "silently downgraded to HTTP/1.1" behavior the epic
    /// exists to replace.
    func testHTTP2NegotiationFallsBackToHTTP1_1ThroughMITM() throws {
        let harness = try makeH1OriginHarness(originBody: "{\"h1-fallback\":true}")
        defer { harness.stop() }

        let result = try harness.curl(["--http2"], path: "/h1-fallback")
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"h1-fallback\":true}")

        let flow = harness.collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow, "the MITM'd exchange must be captured")
        XCTAssertEqual(flow?.response?.statusCode, 200)
        XCTAssertEqual(flow?.isIntercepted, true)
        XCTAssertEqual(flow?.request.httpVersion, "HTTP/1.1", "the client must be silently downgraded to HTTP/1.1 today")
        XCTAssertEqual(flow?.response?.httpVersion, "HTTP/1.1")
    }

    /// A client that refuses to fall back — `--http2-prior-knowledge` — speaks h2 straight
    /// into the HTTP/1 decoder. Today that tears the connection down: the preface cannot be
    /// parsed as a request and the exchange never completes. Phase 1+ replaces this.
    func testHTTP2PriorKnowledgeAgainstMITMIsRejectedToday() throws {
        let harness = try makeH1OriginHarness(originBody: "{\"never\":true}")
        defer { harness.stop() }

        let result = try harness.curl(["--http2-prior-knowledge"], path: "/prior-knowledge")
        XCTAssertNotEqual(result.status, 0, "prior-knowledge h2 into an HTTP/1-only MITM must fail today; curl said: \(result.output)")
        let flow = harness.collector.waitForCompletedFlow(timeout: 2)
        XCTAssertNil(flow?.response, "no response can be captured when the preface is unparsable")
    }

    // MARK: - MITM on, origin requires h2

    /// An origin that speaks nothing but h2 is unreachable through the MITM today: the
    /// upstream leg offers no ALPN and then frames the request as HTTP/1.1, which an
    /// h2 origin cannot accept. Pinned as the Phase 1/2 target.
    func testH2OnlyOriginIsUnreachableThroughMITMToday() throws {
        let harness = try makeH2OriginHarness(alpn: .h2Only, originBody: "{\"h2-only\":true}")
        defer { harness.stop() }

        let result = try harness.curl(["--http2"], path: "/h2-only")
        XCTAssertNotEqual(result.status, 0, "an h2-only origin must be unreachable through MITM today; curl said: \(result.output)")
        let flow = harness.collector.waitForCompletedFlow(timeout: 2)
        XCTAssertNil(flow?.response, "the request never gets a response from an h2-only origin")
    }

    // MARK: - MITM off (opaque tunnel)

    /// CONNECT (and the equivalent SOCKS5 path) relays TLS bytes untouched, so an h2
    /// conversation between client and origin already works — it is just invisible.
    func testCONNECTTunnelRelaysHTTP2ToAnH2OnlyOrigin() throws {
        let harness = try makeH2OriginHarness(alpn: .h2Only, originBody: "{\"opaque-h2\":true}")
        defer { harness.stop() }
        harness.engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"])

        let result = try harness.curl(["--http2"], path: "/opaque", trustOriginCA: true)
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"opaque-h2\":true}")
        XCTAssertTrue(harness.collector.all.isEmpty, "an excluded host must not produce a decrypted flow")
    }

    // MARK: - gRPC sample traffic (h2)

    /// gRPC is the canonical h2 workload. Through an opaque tunnel the whole exchange —
    /// request, response DATA, and `grpc-status` trailers — relays verbatim.
    func testGRPCTrafficRelaysThroughAnOpaqueTunnel() throws {
        let harness = try makeH2OriginHarness(alpn: .h2Only, originBody: "grpc-payload", mode: .grpc)
        defer { harness.stop() }
        harness.engine.sslProxyingPolicy = SSLProxyingPolicy(exclude: ["127.0.0.1"])

        let result = try harness.curl(
            ["--http2-prior-knowledge", "--request", "POST", "--header", "content-type: application/grpc", "--data", "grpc-request"],
            path: "/pkg.Service/Method",
            trustOriginCA: true
        )
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertTrue(result.output.contains("grpc-payload"), "the h2 DATA frame body must survive the tunnel: \(result.output)")
        XCTAssertTrue(harness.collector.all.isEmpty, "an opaque tunnel records no flow")
    }

    /// Sanity check for the fixture itself: the h2 origin serves real HTTP/2 to a direct
    /// (non-proxied) client, so the pins above mean what they claim.
    func testH2TestServerServesHTTP2Directly() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let leaf = try ca.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try H2TestServer(
            alpn: .h2Only,
            certificatePEM: leaf.certificatePEM,
            privateKeyPEM: leaf.privateKeyPEM,
            body: "{\"direct-h2\":true}"
        )
        let port = try origin.start()
        defer { origin.stop() }

        let caURL = writeCACert(ca)
        defer { try? FileManager.default.removeItem(at: caURL) }

        let result = try Self.runCurl([
            "-sS", "--max-time", "20",
            "--http2-prior-knowledge",
            "--cacert", caURL.path,
            "https://127.0.0.1:\(port)/direct",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "{\"direct-h2\":true}")
    }

    // MARK: - Harness

    /// One harness = proxy + TLS origin + collected flows. `stop` shuts down whichever
    /// origin backs it, so every fixture must call it exactly once via `defer`.
    private struct Harness {
        let engine: ProxyEngine
        let collector: FlowCollector
        let originPort: Int
        /// The proxy's CA: curl verifies the MITM leaf against it. MITM'd fixtures use this.
        let caURL: URL
        /// The origin's CA: an opaque tunnel leaves the origin's TLS intact, so curl must
        /// verify the origin leaf against it instead. Opaque fixtures use this.
        let originCAURL: URL
        let stopOrigin: () -> Void

        func curl(_ options: [String], path: String, trustOriginCA: Bool = false) throws -> CurlResult {
            var arguments: [String] = ["-sS", "--max-time", "20"]
            arguments.append(contentsOf: options)
            arguments.append(contentsOf: [
                "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
                "--cacert", (trustOriginCA ? originCAURL : caURL).path,
                "https://127.0.0.1:\(originPort)\(path)",
            ])
            return try HTTP2Phase0Tests.runCurl(arguments)
        }

        func stop() {
            engine.stop()
            stopOrigin()
        }
    }

    /// Proxy + an HTTP/1.1 origin (`OriginServer`, no ALPN), for pinning the fallback
    /// and preface-rejection behavior on the MITM leg.
    private func makeH1OriginHarness(originBody: String) throws -> Harness {
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try OriginServer(
            tls: true,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: originBody
        )
        let originPort = try origin.start()
        return try makeHarness(originPort: originPort, originCA: originCA) {
            origin.stop()
        }
    }

    /// Proxy + an HTTP/2 origin (`H2TestServer`), for pinning tunnel relay behavior and
    /// the h2-only-origin gap.
    private func makeH2OriginHarness(
        alpn: H2TestServer.ALPNConfiguration,
        originBody: String,
        mode: H2TestServer.ResponseMode = .plain
    ) throws -> Harness {
        let originCA = try CertificateAuthority(commonName: "ProxyKit Origin CA")
        let originLeaf = try originCA.makeLeafCertificate(forHost: "127.0.0.1")
        let origin = try H2TestServer(
            alpn: alpn,
            mode: mode,
            certificatePEM: originLeaf.certificatePEM,
            privateKeyPEM: originLeaf.privateKeyPEM,
            body: originBody
        )
        let originPort = try origin.start()
        return try makeHarness(originPort: originPort, originCA: originCA) {
            origin.stop()
        }
    }

    private func makeHarness(originPort: Int, originCA: CertificateAuthority, stopOrigin: @escaping () -> Void) throws -> Harness {
        let engineCA = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: engineCA
        )
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()

        // curl verifies the MITM leaf against the proxy's CA, not the origin's.
        return Harness(
            engine: engine,
            collector: collector,
            originPort: originPort,
            caURL: writeCACert(engineCA),
            originCAURL: writeCACert(originCA),
            stopOrigin: stopOrigin
        )
    }

    private func writeCACert(_ ca: CertificateAuthority) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("proxymaxx-test-\(UUID().uuidString).pem")
        try? ca.certificatePEM.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private struct CurlResult {
        let status: Int32
        let output: String
    }

    private static func runCurl(_ arguments: [String]) throws -> CurlResult {
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
