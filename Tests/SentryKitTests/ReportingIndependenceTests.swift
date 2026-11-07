import XCTest
import Logging
import LogKit
import Sentry
@testable import SentryKit

/// Sentry and LogKit are independent: reporting may be off, unavailable, or broken,
/// and the rotating local log keeps working exactly the same.
final class ReportingIndependenceTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReportingIndependence-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logFile(maxFileBytes: Int = 8, maxFiles: Int = 3) -> RotatingLogFile {
        RotatingLogFile(url: directory.appendingPathComponent("0.log"), maxFileBytes: maxFileBytes, maxFiles: maxFiles)
    }

    func testLocalLogKeepsWritingWhileReportingIsDisabled() {
        let file = logFile(maxFileBytes: 1_000)
        let service = SentryCrashReportingService(dsn: "https://publickey@o1.ingest.us.sentry.io/4512386169438208", backend: SilentBackend())

        service.capture(error: NSError(domain: "test", code: 1), context: nil)
        file.append("first line after a dropped report")
        service.enable()
        service.disable()
        file.append("second line after a disabled reporter")

        XCTAssertEqual(
            file.latestLines(10),
            ["first line after a dropped report", "second line after a disabled reporter"]
        )
    }

    func testRotationIsUnaffectedByReporting() {
        let file = logFile(maxFileBytes: 8, maxFiles: 3)
        let service = NoOpCrashReportingService()
        for index in 0..<5 {
            service.capture(error: NSError(domain: "test", code: index), context: nil)
            file.append("line\(index)")
        }

        XCTAssertEqual(file.latestLines(1), ["line4"])
        XCTAssertEqual(file.allText(), "line2\nline3\nline4\n")
    }

    /// A captured report goes through the abstraction; the logger writes its own line
    /// through its own handler. Neither path is a prerequisite for the other.
    func testCapturingAndStructuredLoggingAreSeparatePaths() throws {
        let backend = CountingBackend()
        let service = SentryCrashReportingService(dsn: "https://publickey@o1.ingest.us.sentry.io/4512386169438208", backend: backend)
        service.enable()

        let file = logFile(maxFileBytes: 1_000)
        var handler = StructuredLogHandler(label: "oss.proxymaxx.proxykit.engine")
        handler.logLevel = .trace
        let logger = Logger(label: "oss.proxymaxx.proxykit.engine", factory: { _ in handler })
        logger.error("engine stopped", metadata: ["error_code": "bind-failed"])
        service.capture(error: NSError(domain: "test", code: 9), context: nil)

        // The capture reached the reporter, and did not append anything of its own.
        XCTAssertEqual(backend.captures, 1)
        for line in file.latestLines(20) {
            XCTAssertFalse(line.contains("NSError"), line)
        }
    }

    func testIssueReporterBodyNeverIncludesRotatedFiles() {
        let file = logFile(maxFileBytes: 8, maxFiles: 3)
        for index in 0..<5 {
            file.append("line\(index)")
        }
        let body = IssueReporter.body(logFile: file)
        XCTAssertTrue(body.contains("line4"))
        // 0.log only: `line0` and `line1` already rotated out.
        XCTAssertFalse(body.contains("line0"))
        XCTAssertFalse(body.contains("line1"))
    }
}

private final class SilentBackend: SentryBackend {
    func start(options: Options) -> Bool { true }
    func close() {}
    func capture(error: Error, context: DiagnosticContext?) {}
}

private final class CountingBackend: SentryBackend {
    private(set) var captures = 0
    func start(options: Options) -> Bool { true }
    func close() {}
    func capture(error: Error, context: DiagnosticContext?) { captures += 1 }
}
