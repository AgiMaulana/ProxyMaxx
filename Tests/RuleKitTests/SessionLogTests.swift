import XCTest
import Foundation
import FlowKit
import RuleKit

/// Contract tests for the session log's tailing reader.
///
/// The engine emits several snapshots per flow (request, response head, throttled body,
/// completion). A tail that polls the log must still print one line per flow, and must
/// not print the same flow again when compaction rewinds its byte offset.
final class SessionLogFollowerTests: XCTestCase {
    private var directory: URL!
    private var url: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("sessionlog-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        url = directory.appendingPathComponent("session.ndjson")
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testSnapshotArrivingAcrossPollsPrintsTheFlowOnce() throws {
        let writer = SessionLog.Writer(url: url)
        var follower = SessionLog.Follower(url: url)

        // Request set: the flow has started but not closed.
        var captured = makeFlow("/slow", closed: false)
        writer.append(captured)
        XCTAssertTrue(follower.poll().isEmpty, "an open flow must not be printed yet")

        // Response head: still no closing snapshot.
        captured.response = HTTPResponse(statusCode: 200, body: Data("partial".utf8))
        writer.append(captured)
        XCTAssertTrue(follower.poll().isEmpty)

        // Body drains, then the flow closes.
        captured.response?.body.append(Data("+more".utf8))
        captured.timing.end = Date()
        writer.append(captured)

        let closed = follower.poll()
        XCTAssertEqual(closed.count, 1)
        XCTAssertEqual(closed.first?.request.path, "/slow")
        XCTAssertEqual(closed.first?.response?.body, Data("partial+more".utf8))
        XCTAssertNotNil(closed.first?.timing.end, "the printed line carries the closing timing")
        XCTAssertTrue(follower.poll().isEmpty, "a closed flow is never printed twice")
    }

    func testSnapshotsWithinOnePollCollapseToTheClosingLine() throws {
        let writer = SessionLog.Writer(url: url)
        var follower = SessionLog.Follower(url: url)

        var captured = makeFlow("/batch", closed: false)
        writer.append(captured)
        captured.response = HTTPResponse(statusCode: 200, body: Data("a".utf8))
        writer.append(captured)
        captured.response?.body.append(Data("b".utf8))
        writer.append(captured)
        captured.timing.end = Date()
        writer.append(captured)

        let closed = follower.poll()
        XCTAssertEqual(closed.map(\.request.path), ["/batch"])
        XCTAssertEqual(closed.first?.response?.body, Data("ab".utf8))
    }

    func testClosedFlowsKeepCaptureOrder() throws {
        let writer = SessionLog.Writer(url: url)
        var follower = SessionLog.Follower(url: url)

        writer.append(makeFlow("/first"))
        writer.append(makeFlow("/second"))
        writer.append(makeFlow("/third"))

        XCTAssertEqual(follower.poll().map(\.request.path), ["/first", "/second", "/third"])
    }

    func testOpenFlowIsPrintedFromItsLatestSnapshotOnFinish() throws {
        let writer = SessionLog.Writer(url: url)
        var follower = SessionLog.Follower(url: url)

        var captured = makeFlow("/open", body: "early", closed: false)
        writer.append(captured)
        XCTAssertTrue(follower.poll().isEmpty)

        // The response arrives, but the flow never closes.
        captured.response = HTTPResponse(statusCode: 200, body: Data("late".utf8))
        writer.append(captured)

        let open = follower.finish()
        XCTAssertEqual(open.map(\.request.path), ["/open"])
        XCTAssertEqual(open.first?.response?.body, Data("late".utf8))
        XCTAssertTrue(follower.finish().isEmpty, "finishing surfaces the flow only once")
        XCTAssertTrue(follower.poll().isEmpty)
    }

    /// The engine can close a flow between the last poll and the moment it stops owning
    /// the engine, so finishing has to read the tail rather than only drain memory.
    func testFinishReadsTheTailWrittenAfterTheLastPoll() throws {
        let writer = SessionLog.Writer(url: url)
        var follower = SessionLog.Follower(url: url)

        writer.append(makeFlow("/before"))
        XCTAssertEqual(follower.poll().map(\.request.path), ["/before"])

        writer.append(makeFlow("/after"))
        XCTAssertEqual(follower.finish().map(\.request.path), ["/after"])
    }

    /// Compaction rewrites the log smaller, which sends the follower's offset back to
    /// zero and replays lines it has already read. Those must not be printed again.
    func testCompactionReplayDoesNotRepeatASurfacedFlow() throws {
        let writer = SessionLog.Writer(url: url, maxLines: 2)
        var follower = SessionLog.Follower(url: url)

        writer.append(makeFlow("/a"))
        XCTAssertEqual(follower.poll().map(\.request.path), ["/a"])

        writer.append(makeFlow("/b"))
        XCTAssertEqual(follower.poll().map(\.request.path), ["/b"])

        // The third line trips the cap: the log keeps only its newest line, dropping
        // both flows the follower has already printed.
        writer.append(makeFlow("/c"))
        XCTAssertEqual(follower.poll().map(\.request.path), ["/c"])
        XCTAssertTrue(follower.poll().isEmpty)
    }

    private func makeFlow(_ path: String, body: String = "hello", closed: Bool = true) -> Flow {
        var flow = Flow(request: HTTPRequest(
            method: "GET",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: path,
            body: Data(body.utf8)
        ))
        if closed {
            flow.response = HTTPResponse(statusCode: 200, body: Data(body.utf8))
            flow.timing.end = Date()
        }
        return flow
    }
}
