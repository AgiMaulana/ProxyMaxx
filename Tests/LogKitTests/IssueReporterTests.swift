import XCTest
@testable import LogKit

final class IssueReporterTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogKitReporter-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logFile() -> RotatingLogFile {
        RotatingLogFile(url: directory.appendingPathComponent("0.log"), maxFileBytes: 1_000_000)
    }

    func testBodyIncludesVersionAndLogTail() {
        let file = logFile()
        file.append("2026-11-07 10:00:00.123 [info] [Proxykit.Engine] listening")
        let body = IssueReporter.body(logFile: file)
        XCTAssertTrue(body.contains("ProxyMaxx"))
        XCTAssertTrue(body.contains("listening"))
        XCTAssertTrue(body.contains("Latest logs"))
    }

    func testBodyNotesEmptyLog() {
        XCTAssertTrue(IssueReporter.body(logFile: logFile()).contains("empty"))
    }

    func testBodyRedactsSecretsAndWarnsBeforeSubmission() {
        let file = logFile()
        file.append(#"Authorization: Bearer abc123 password=hunter2 /Users/alice/file.log"#)
        let body = IssueReporter.body(logFile: file)
        XCTAssertFalse(body.contains("abc123"))
        XCTAssertFalse(body.contains("hunter2"))
        XCTAssertFalse(body.contains("alice"))
        XCTAssertTrue(body.contains("Privacy"))
        XCTAssertTrue(body.contains("does not submit"))
    }

    func testIssueURLCarriesTitleAndBody() throws {
        let file = logFile()
        file.append("boom")
        let url = try XCTUnwrap(IssueReporter.issueURL(logFile: file))
        let components = try XCTUnwrap(URLComponents(url: url, resolvingAgainstBaseURL: false))
        XCTAssertEqual(components.host, "github.com")
        XCTAssertEqual(components.path, "/AgiMaulana/ProxyMaxx/issues/new")
        let items = Dictionary(uniqueKeysWithValues: (components.queryItems ?? []).map { ($0.name, $0.value) })
        let title = try XCTUnwrap(items["title"] ?? nil)
        let body = try XCTUnwrap(items["body"] ?? nil)
        XCTAssertEqual(title, "Report: boom")
        XCTAssertTrue(body.contains("boom"))
    }

    func testBodyIsTruncatedBelowGitHubLimit() throws {
        let file = logFile()
        for index in 0..<2_000 {
            file.append("line \(index) \(String(repeating: "x", count: 40))")
        }
        let body = IssueReporter.body(logFile: file)
        XCTAssertLessThanOrEqual(body.count, IssueReporter.maxBodyCharacters + 100)
        XCTAssertTrue(IssueReporter.issueURL(logFile: file) != nil)
    }
}
