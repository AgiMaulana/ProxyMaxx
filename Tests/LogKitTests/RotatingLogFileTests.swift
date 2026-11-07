import XCTest
@testable import LogKit

final class RotatingLogFileTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("LogKitTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func logFile(maxFileBytes: Int = 64, maxFiles: Int = 3) -> RotatingLogFile {
        RotatingLogFile(url: directory.appendingPathComponent("0.log"), maxFileBytes: maxFileBytes, maxFiles: maxFiles)
    }

    private func contents(_ index: Int) -> String? {
        let url = directory.appendingPathComponent("\(index).log")
        guard let data = try? Data(contentsOf: url) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }

    func testAppendCreatesDirectoryAndFile() throws {
        let nested = directory.appendingPathComponent("Logs/0.log")
        let log = RotatingLogFile(url: nested)
        log.append("first")
        XCTAssertEqual(try String(contentsOf: nested, encoding: .utf8), "first\n")
    }

    func testRotationMovesNewestToZeroAndOldestUp() {
        let log = logFile(maxFileBytes: 20, maxFiles: 3)
        log.append("aaaaaaaaaa")
        log.append("bbbbbbbbbb")
        log.append("cccccccccc")

        XCTAssertEqual(contents(0), "cccccccccc\n")
        XCTAssertEqual(contents(1), "bbbbbbbbbb\n")
        XCTAssertEqual(contents(2), "aaaaaaaaaa\n")
    }

    func testRotationDropsOldestWhenRingIsFull() {
        let log = logFile(maxFileBytes: 8, maxFiles: 3)
        for index in 0..<5 {
            log.append("line\(index)")
        }

        XCTAssertEqual(contents(0), "line4\n")
        XCTAssertEqual(contents(1), "line3\n")
        XCTAssertEqual(contents(2), "line2\n")
        XCTAssertNil(contents(3))
    }

    func testRotationNeverExceedsConfiguredFileCount() {
        let log = logFile(maxFileBytes: 4, maxFiles: 10)
        for index in 0..<50 {
            log.append(String(repeating: "\(index % 10)", count: 3))
        }
        let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path)
        XCTAssertEqual(names?.count, 10)
    }

    func testLatestTextReturnsTailOnLineBoundary() {
        let log = logFile(maxFileBytes: 1_000, maxFiles: 2)
        log.append("alpha")
        log.append("beta")
        log.append("gamma")

        XCTAssertEqual(log.latestText(maxBytes: 12), "beta\ngamma\n")
        XCTAssertEqual(log.latestLines(2), ["beta", "gamma"])
    }

    func testLatestTextOfMissingFileIsNil() {
        XCTAssertNil(logFile().latestText(maxBytes: 100))
    }

    func testAllTextIsOldestFirst() {
        let log = logFile(maxFileBytes: 8, maxFiles: 3)
        for index in 0..<4 {
            log.append("line\(index)")
        }
        XCTAssertEqual(log.allText(), "line1\nline2\nline3\n")
    }
}
