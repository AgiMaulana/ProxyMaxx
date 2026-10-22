import XCTest
import Foundation
import FlowKit
@testable import RuleKit

/// Contract tests for the GUI ↔ CLI ownership handoff. Every test works inside its own
/// temp directory so a real `Application Support` record can never leak into them.
final class ProxyRegistryTests: XCTestCase {
    private var directory: URL!
    private var ownPid = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rulekit-registry-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ownPid = Int(ProcessInfo.processInfo.processIdentifier)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    func testRoundTripKeepsOwnerAndPorts() throws {
        let entry = ProxyRegistryEntry(owner: .cli, pid: ownPid, httpPort: 9090, socksPort: 8989)
        try ProxyRegistry.write(entry, directory: directory)
        let read = ProxyRegistry.read(directory: directory)
        XCTAssertEqual(read?.owner, entry.owner)
        XCTAssertEqual(read?.pid, entry.pid)
        XCTAssertEqual(read?.httpPort, entry.httpPort)
        XCTAssertEqual(read?.socksPort, entry.socksPort)
        // Timestamps ride seconds-since-1970 doubles, so assert Double fidelity (1 ms),
        // not Date identity.
        let a = read!.startedAt.timeIntervalSince1970
        let b = entry.startedAt.timeIntervalSince1970
        XCTAssertEqual(a, b, accuracy: 0.001)
    }

    func testClearRemovesTheRecord() throws {
        let entry = ProxyRegistryEntry(owner: .app, pid: ownPid, httpPort: 9090, socksPort: nil)
        try ProxyRegistry.write(entry, directory: directory)
        ProxyRegistry.clear(directory: directory)
        XCTAssertNil(ProxyRegistry.read(directory: directory))
    }

    func testDeadPidReadsAsNoOwner() throws {
        // A pid that has exited must never be reported as an owner, otherwise a crashed
        // run would block every later serve and app start.
        let dead = ProxyRegistryEntry(owner: .cli, pid: 999_999_999, httpPort: 9090, socksPort: nil)
        try ProxyRegistry.write(dead, directory: directory)
        XCTAssertNil(ProxyRegistry.read(directory: directory))
    }

    func testMissingFileReadsAsNoOwner() {
        XCTAssertNil(ProxyRegistry.read(directory: directory))
    }

    func testSocksPortIsOptional() throws {
        let entry = ProxyRegistryEntry(owner: .app, pid: ownPid, httpPort: 9090, socksPort: nil)
        try ProxyRegistry.write(entry, directory: directory)
        XCTAssertNil(ProxyRegistry.read(directory: directory)?.socksPort)
    }
}

final class CommandIPCTests: XCTestCase {
    private var directory: URL!
    private var ownPid = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rulekit-ipctests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        ownPid = Int(ProcessInfo.processInfo.processIdentifier)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func publishFakeOwner() throws {
        try ProxyRegistry.write(
            ProxyRegistryEntry(owner: .app, pid: ownPid, httpPort: 9090, socksPort: nil),
            directory: directory
        )
    }

    /// The whole loop a real run exercises: the CLI waits on a request, the app picks
    /// it up, applies it, and responds; the CLI unblocks.
    func testRequestRoundTripThroughConsumer() throws {
        try publishFakeOwner()
        // The consumer answers on its own thread while the CLI call blocks, exactly the
        // two halves a real run has.
        let consumer = Thread {
            var waited: TimeInterval = 0
            while waited < 5 {
                if let request = CommandIPC.pendingMessages(directory: self.directory).first {
                    let response = CommandIPC.Result(id: request.message.id, ok: true, rule: request.message.rule)
                    try? CommandIPC.respond(response, directory: self.directory)
                    return
                }
                Thread.sleep(forTimeInterval: 0.05)
                waited += 0.05
            }
        }
        consumer.start()

        let rule = MapLocalRule(
            name: "cli test",
            url: "example.com/v1/*",
            destination: .file("/tmp/stub.json")
        )
        let delivered = CommandIPC.request(.init(op: .add, rule: rule), directory: directory, timeout: 5)
        XCTAssertNotNil(delivered)
        XCTAssertEqual(delivered?.ok, true)
        XCTAssertEqual(delivered?.rule?.url, "example.com/v1/*")
    }

    func testRequestTimesOutWhenNobodyAnswers() {
        let started = Date()
        let outcome = CommandIPC.request(.init(op: .clear), directory: directory, timeout: 0.4)
        XCTAssertNil(outcome)
        XCTAssertLessThan(Date().timeIntervalSince(started), 3)
        // The request file must not outlive its own timeout.
        let leftovers = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        XCTAssertTrue(leftovers.isEmpty, "leftover files: \(leftovers)")
    }

    func testStaleRequestsAreDroppedOnRead() throws {
        try publishFakeOwner()
        let ancient = CommandIPC.Message(op: .add, rule: MapLocalRule(url: "old.example.com"))
        let values = (try? JSONEncoder().encode(ancient)) ?? Data()
        let requestURL = directory.appendingPathComponent("ipc/request-\(ancient.id).json")
        try FileManager.default.createDirectory(
            at: requestURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try values.write(to: requestURL)
        // Backdate past the staleness window, as if the CLI ran a minute ago and died.
        try FileManager.default.setAttributes(
            [.creationDate: Date().addingTimeInterval(-(CommandIPC.staleAfter + 30))],
            ofItemAtPath: requestURL.path
        )
        XCTAssertTrue(CommandIPC.pendingMessages(directory: directory).isEmpty)
    }

    func testPendingMessagesIgnoreForeignFiles() throws {
        try publishFakeOwner()
        let base = directory.appendingPathComponent("ipc")
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        let response = base.appendingPathComponent("response-anything.json")
        try Data("{}".utf8).write(to: response)
        XCTAssertTrue(CommandIPC.pendingMessages(directory: directory).isEmpty)
    }

    /// A request written by an older build (no tool/list/pattern/add fields) must still
    /// decode, or upgrading the CLI and the app independently would strand requests.
    func testLegacyPayloadDecodesWithNewFieldsNil() throws {
        let json = #"{"id":"A","op":"clear","createdAt":0}"#
        let message = try ProxyRegistry.decoder.decode(CommandIPC.Message.self, from: Data(json.utf8))
        XCTAssertEqual(message.op, .clear)
        XCTAssertNil(message.tool)
        XCTAssertNil(message.list)
        XCTAssertNil(message.pattern)
        XCTAssertNil(message.add)
        XCTAssertNil(message.enabled)
    }

    /// The parity operations carry their payload across the file store intact. Compares
    /// the fields, not the whole value: `createdAt` rides seconds-since-1970 and so is not
    /// bit-identical after a round trip.
    func testParityOperationPayloadsRoundTrip() throws {
        let messages: [CommandIPC.Message] = [
            .init(op: .setToolEnabled, tool: "map-local", enabled: false),
            .init(op: .setSSLProxying, list: "exclude", pattern: "*.apple.com", add: true),
            .init(op: .update, rule: MapLocalRule(url: "example.com/*", destination: .file("/tmp/x.json"))),
            .init(op: .clearSession),
        ]
        for message in messages {
            let data = try ProxyRegistry.encoder.encode(message)
            let decoded = try ProxyRegistry.decoder.decode(CommandIPC.Message.self, from: data)
            XCTAssertEqual(decoded.op, message.op)
            XCTAssertEqual(decoded.tool, message.tool)
            XCTAssertEqual(decoded.enabled, message.enabled)
            XCTAssertEqual(decoded.list, message.list)
            XCTAssertEqual(decoded.pattern, message.pattern)
            XCTAssertEqual(decoded.add, message.add)
            XCTAssertEqual(decoded.rule, message.rule)
        }
    }
}

/// Contract tests for the shared flow spool: the hand-off buffer that lets the window
/// watch traffic captured by a CLI-hosted engine, and vice versa.
final class FlowSpoolTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("rulekit-flowspool-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func flow(_ path: String, status: Int? = nil, body: String = "hello") -> Flow {
        var flow = Flow(request: HTTPRequest(
            method: "GET",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: path,
            body: Data(body.utf8)
        ))
        if let status {
            flow.response = HTTPResponse(statusCode: status, body: Data(body.utf8))
        }
        return flow
    }

    func testWriterSnapshotIsReadableByTheOtherFrontEnd() throws {
        let writer = FlowSpool.Writer(directory: directory)
        let captured = flow("/a", status: 200)
        writer.write(captured)

        let pending = FlowSpool.pendingURLs(directory: directory)
        XCTAssertEqual(pending.count, 1)
        let decoded = try XCTUnwrap(FlowSpool.read(pending[0]))
        XCTAssertEqual(decoded.id, captured.id)
        XCTAssertEqual(decoded.request.path, "/a")
        XCTAssertEqual(decoded.response?.statusCode, 200)
        // The body must survive the hand-off, because the inspector shows it.
        XCTAssertEqual(decoded.response?.body, Data("hello".utf8))
    }

    /// A flow streams as request-set, response-head, throttled body and complete
    /// snapshots. They must collapse onto one file, not one file per tick.
    func testRepeatedSnapshotsCollapseToOneFile() throws {
        let writer = FlowSpool.Writer(directory: directory)
        var current = flow("/slow")
        writer.write(current)
        current.response = HTTPResponse(statusCode: 200, body: Data("partial".utf8))
        writer.write(current)
        current.response?.body.append(Data("+more".utf8))
        writer.write(current)

        let pending = FlowSpool.pendingURLs(directory: directory)
        XCTAssertEqual(pending.count, 1)
        let decoded = try XCTUnwrap(FlowSpool.read(pending[0]))
        XCTAssertEqual(decoded.response?.body, Data("partial+more".utf8))
    }

    func testSnapshotsReplayInCaptureOrder() throws {
        let writer = FlowSpool.Writer(directory: directory)
        let first = flow("/first")
        let second = flow("/second")
        let third = flow("/third")
        writer.write(first)
        writer.write(second)
        writer.write(third)

        let paths = FlowSpool.pendingURLs(directory: directory).compactMap {
            FlowSpool.read($0)?.request.path
        }
        XCTAssertEqual(paths, ["/first", "/second", "/third"])
    }

    /// The reader deletes what it consumed; a later snapshot under a fresh name must
    /// still be there, even if the writer replaces the flow the reader just took.
    func testConsumedSnapshotDoesNotHideTheNextUpdate() throws {
        let writer = FlowSpool.Writer(directory: directory)
        let original = flow("/x", status: 200, body: "one")
        writer.write(original)

        let consumed = try XCTUnwrap(FlowSpool.pendingURLs(directory: directory).first)
        _ = FlowSpool.read(consumed)
        FlowSpool.remove(consumed)

        // The writer streams a fresh snapshot for the same flow afterwards.
        var updated = original
        updated.response?.body = Data("two".utf8)
        writer.write(updated)

        let remaining = FlowSpool.pendingURLs(directory: directory)
        XCTAssertEqual(remaining.count, 1)
        XCTAssertEqual(try XCTUnwrap(FlowSpool.read(remaining[0])).response?.body, Data("two".utf8))
    }

    func testResetDropsStaleSnapshots() throws {
        let writer = FlowSpool.Writer(directory: directory)
        writer.write(flow("/stale"))
        XCTAssertEqual(FlowSpool.pendingURLs(directory: directory).count, 1)

        writer.reset()
        XCTAssertTrue(FlowSpool.pendingURLs(directory: directory).isEmpty)
    }

    func testClearRemovesSnapshots() throws {
        let writer = FlowSpool.Writer(directory: directory)
        writer.write(flow("/a"))
        writer.write(flow("/b"))
        writer.clear()
        XCTAssertTrue(FlowSpool.pendingURLs(directory: directory).isEmpty)
    }
}
