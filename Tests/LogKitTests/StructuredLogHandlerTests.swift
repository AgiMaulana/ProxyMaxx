import XCTest
import Logging
@testable import LogKit

final class StructuredLogHandlerTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogKitHandler-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testLineCarriesTimestampLevelComponentMessageAndMetadata() throws {
        let file = RotatingLogFile(url: directory.appendingPathComponent("0.log"))
        var handler = StructuredLogHandler(label: "oss.proxymaxx.proxykit.engine", file: file)
        let logger = Logger(label: "oss.proxymaxx.proxykit.engine", factory: { _ in handler })
        logger.info("proxy listening", metadata: ["port": "9090", "correlation-id": "abc123"])

        let line = try XCTUnwrap(file.latestLines(1).first)
        XCTAssertTrue(line.hasSuffix("[Proxykit.Engine] proxy listening correlation-id=abc123 port=9090"), line)
        XCTAssertTrue(line.range(of: #"^\d{4}-\d{2}-\d{2} \d{2}:\d{2}:\d{2}\.\d{3} \[info\] "#, options: .regularExpression) != nil, line)
    }

    func testDefaultMetadataIsIncluded() throws {
        let file = RotatingLogFile(url: directory.appendingPathComponent("0.log"))
        var handler = StructuredLogHandler(label: "oss.proxymaxx.cli", file: file)
        handler[metadataKey: "operation"] = "serve"
        let logger = Logger(label: "oss.proxymaxx.cli", factory: { _ in handler })
        logger.warning("started")

        let line = try XCTUnwrap(file.latestLines(1).first)
        XCTAssertTrue(line.contains("[Cli] started operation=serve"), line)
    }

    func testMultiWordValuesAreQuoted() throws {
        let file = RotatingLogFile(url: directory.appendingPathComponent("0.log"))
        var handler = StructuredLogHandler(label: "oss.proxymaxx.app", file: file)
        let logger = Logger(label: "oss.proxymaxx.app", factory: { _ in handler })
        logger.error("failed", metadata: ["error": "connection reset"])

        let line = try XCTUnwrap(file.latestLines(1).first)
        XCTAssertTrue(line.contains(#"error="connection reset""#), line)
    }
}
