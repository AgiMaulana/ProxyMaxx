import XCTest
import Foundation
@testable import ProxyKit
import CertKit
import FlowKit

final class CaptureCapIntegrationTests: XCTestCase {
    func testClientReceivesAllBytesWhileCaptureIsCapped() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let fullPayload = String(repeating: "A", count: 4096)
        let origin = try OriginServer(tls: false, body: fullPayload, contentType: "text/plain")
        let originPort = try origin.start()
        defer { origin.stop() }

        let config = ProxyConfiguration(
            host: "127.0.0.1",
            port: 0,
            socksPort: nil,
            maxCapturedResponseBodyBytes: 1024
        )
        let engine = try ProxyEngine(configuration: config, authority: ca)
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "http://127.0.0.1:\(originPort)/large-response",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output.count, 4096, "client must receive all 4096 bytes from upstream")
        XCTAssertEqual(result.output, fullPayload)

        let flow = collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow)
        XCTAssertEqual(flow?.response?.statusCode, 200)
        XCTAssertEqual(flow?.response?.body.count, 1024, "captured response body must be capped at 1024 bytes")
        XCTAssertEqual(flow?.responseBodyTruncated, true)
    }

    func testClientSendsFullRequestBodyWhileCapturedRequestIsCapped() throws {
        let ca = try CertificateAuthority(commonName: "ProxyKit Test CA")
        let origin = try OriginServer(tls: false, body: "ok", contentType: "text/plain")
        let originPort = try origin.start()
        defer { origin.stop() }

        let config = ProxyConfiguration(
            host: "127.0.0.1",
            port: 0,
            socksPort: nil,
            maxCapturedRequestBodyBytes: 512
        )
        let engine = try ProxyEngine(configuration: config, authority: ca)
        let collector = FlowCollector()
        engine.onEvent = { collector.handle($0) }
        try engine.start()
        defer { engine.stop() }

        let largeRequestBody = String(repeating: "B", count: 2048)
        let result = try runCurl([
            "-sS", "--max-time", "20",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "-X", "POST",
            "-d", largeRequestBody,
            "http://127.0.0.1:\(originPort)/upload",
        ])
        XCTAssertEqual(result.status, 0, result.output)
        XCTAssertEqual(result.output, "ok")

        let flow = collector.waitForCompletedFlow(timeout: 5)
        XCTAssertNotNil(flow)
        XCTAssertEqual(flow?.request.method, "POST")
        XCTAssertEqual(flow?.request.body.count, 512, "captured request body must be capped at 512 bytes")
        XCTAssertEqual(flow?.requestBodyTruncated, true)
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
