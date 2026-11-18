import XCTest
import Foundation
import FlowKit
@testable import RuleKit

final class FlowPersistenceTests: XCTestCase {
    private var tempDirectory: URL!
    private var spoolDirectory: URL!
    private var sessionLogURL: URL!

    override func setUpWithError() throws {
        tempDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("persistence-test-\(UUID().uuidString)", isDirectory: true)
        spoolDirectory = tempDirectory.appendingPathComponent("spool", isDirectory: true)
        sessionLogURL = tempDirectory.appendingPathComponent("session.ndjson")
        try FileManager.default.createDirectory(at: spoolDirectory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tempDirectory)
    }

    private func makePersistence() -> FlowPersistence {
        let spool = FlowSpool.Writer(directory: spoolDirectory)
        let sessionLog = SessionLog.Writer(url: sessionLogURL)
        return FlowPersistence(spool: spool, sessionLog: sessionLog, metrics: nil)
    }

    private func makeFlow(
        id: UUID = UUID(),
        path: String = "/test",
        requestBody: Data = Data(),
        responseBody: Data = Data(),
        contentType: String? = nil,
        isCompleted: Bool = false,
        error: String? = nil
    ) -> Flow {
        var headers = HTTPHeaders()
        if let contentType {
            headers.add(name: "Content-Type", value: contentType)
        }
        var timing = FlowTiming()
        if isCompleted {
            timing.end = Date()
        }
        let response = (isCompleted || !responseBody.isEmpty || contentType != nil)
            ? HTTPResponse(statusCode: 200, headers: headers, body: responseBody)
            : nil

        return Flow(
            id: id,
            request: HTTPRequest(
                method: "GET",
                scheme: "https",
                host: "example.com",
                port: 443,
                path: path,
                body: requestBody
            ),
            response: response,
            timing: timing,
            error: error
        )
    }

    func testTerminalSnapshotsAreAlwaysPersistedImmediately() async {
        let persistence = makePersistence()
        let t0 = Date()

        // 1. Completed flow with large body
        let largeBody = Data(repeating: 0x41, count: 1024 * 1024) // 1 MiB
        let completedFlow = makeFlow(responseBody: largeBody, isCompleted: true)
        let persisted1 = await persistence.persist(completedFlow, now: t0)
        XCTAssertTrue(persisted1)

        // 2. Error flow
        let errorFlow = makeFlow(error: "Connection reset by peer")
        let persisted2 = await persistence.persist(errorFlow, now: t0)
        XCTAssertTrue(persisted2)

        // Verify session log has both flows
        let recorded = SessionLog.read(url: sessionLogURL)
        XCTAssertEqual(recorded.count, 2)
    }

    func testSmallBodyIntermediateSnapshotsAreThrottledTo500ms() async {
        let persistence = makePersistence()
        let flowId = UUID()
        let smallBody = Data(repeating: 0x41, count: 10 * 1024) // 10 KiB (< 128 KiB)
        let t0 = Date()

        // Initial snapshot at t0 -> should persist
        let initial = makeFlow(id: flowId, responseBody: smallBody, isCompleted: false)
        let p0 = await persistence.persist(initial, now: t0)
        XCTAssertTrue(p0, "Initial snapshot must be persisted")

        // Snapshot at t0 + 100ms -> should be throttled
        let p1 = await persistence.persist(initial, now: t0.addingTimeInterval(0.1))
        XCTAssertFalse(p1, "Snapshot at 100ms must be throttled")

        // Snapshot at t0 + 400ms -> should be throttled
        let p2 = await persistence.persist(initial, now: t0.addingTimeInterval(0.4))
        XCTAssertFalse(p2, "Snapshot at 400ms must be throttled")

        // Snapshot at t0 + 500ms -> should persist
        let p3 = await persistence.persist(initial, now: t0.addingTimeInterval(0.5))
        XCTAssertTrue(p3, "Snapshot at 500ms must be persisted")

        // Snapshot at t0 + 600ms -> should be throttled
        let p4 = await persistence.persist(initial, now: t0.addingTimeInterval(0.6))
        XCTAssertFalse(p4, "Snapshot at 600ms must be throttled")

        // Snapshot at t0 + 1000ms -> should persist
        let p5 = await persistence.persist(initial, now: t0.addingTimeInterval(1.0))
        XCTAssertTrue(p5, "Snapshot at 1.0s must be persisted")
    }

    func testMediumBodyIntermediateSnapshotsAreThrottledTo1s() async {
        let persistence = makePersistence()
        let flowId = UUID()
        let mediumBody = Data(repeating: 0x42, count: 256 * 1024) // 256 KiB (between 128 KiB and 512 KiB)
        let t0 = Date()

        // Initial snapshot at t0 -> should persist
        let initial = makeFlow(id: flowId, responseBody: mediumBody, isCompleted: false)
        let p0 = await persistence.persist(initial, now: t0)
        XCTAssertTrue(p0, "Initial medium body snapshot must be persisted")

        // Snapshot at t0 + 500ms -> should be throttled (medium requires 1.0s)
        let p1 = await persistence.persist(initial, now: t0.addingTimeInterval(0.5))
        XCTAssertFalse(p1, "Medium body at 500ms must be throttled")

        // Snapshot at t0 + 900ms -> should be throttled
        let p2 = await persistence.persist(initial, now: t0.addingTimeInterval(0.9))
        XCTAssertFalse(p2, "Medium body at 900ms must be throttled")

        // Snapshot at t0 + 1000ms -> should persist
        let p3 = await persistence.persist(initial, now: t0.addingTimeInterval(1.0))
        XCTAssertTrue(p3, "Medium body at 1.0s must be persisted")
    }

    func testLargeBodyIntermediateSnapshotsAreFinalOnly() async {
        let persistence = makePersistence()
        let flowId = UUID()
        let largeBody = Data(repeating: 0x43, count: 600 * 1024) // 600 KiB (>= 512 KiB)
        let t0 = Date()

        // Intermediate snapshots should NEVER persist for large bodies
        let intermediate = makeFlow(id: flowId, responseBody: largeBody, isCompleted: false)
        let p0 = await persistence.persist(intermediate, now: t0)
        XCTAssertFalse(p0, "Large body intermediate snapshot must not be persisted")

        let p1 = await persistence.persist(intermediate, now: t0.addingTimeInterval(5.0))
        XCTAssertFalse(p1, "Large body intermediate snapshot after 5s must still not be persisted")

        // Terminal snapshot must be persisted
        let finalFlow = makeFlow(id: flowId, responseBody: largeBody, isCompleted: true)
        let pFinal = await persistence.persist(finalFlow, now: t0.addingTimeInterval(5.1))
        XCTAssertTrue(pFinal, "Final snapshot of large body must be persisted")
    }

    func testStreamingResponseIntermediateSnapshotsAreFinalOnly() async {
        let persistence = makePersistence()
        let flowId = UUID()
        let t0 = Date()

        // Streaming MJPEG CCTV response
        let cctvFlow = makeFlow(
            id: flowId,
            responseBody: Data("frame1".utf8),
            contentType: "multipart/x-mixed-replace; boundary=frame",
            isCompleted: false
        )
        let p0 = await persistence.persist(cctvFlow, now: t0)
        XCTAssertFalse(p0, "CCTV MJPEG intermediate snapshot must not be persisted")

        let p1 = await persistence.persist(cctvFlow, now: t0.addingTimeInterval(2.0))
        XCTAssertFalse(p1, "CCTV MJPEG subsequent intermediate snapshot must not be persisted")

        // SSE text/event-stream
        let sseId = UUID()
        let sseFlow = makeFlow(
            id: sseId,
            responseBody: Data("data: hello\n\n".utf8),
            contentType: "text/event-stream",
            isCompleted: false
        )
        let pSSE = await persistence.persist(sseFlow, now: t0)
        XCTAssertFalse(pSSE, "SSE intermediate snapshot must not be persisted")

        // Completed streaming response must be persisted
        var finalCCTV = cctvFlow
        finalCCTV.timing.end = t0.addingTimeInterval(3.0)
        let pCCTVFinal = await persistence.persist(finalCCTV, now: t0.addingTimeInterval(3.0))
        XCTAssertTrue(pCCTVFinal, "Completed CCTV response must be persisted")
    }

    func testFlushPersistsInFlightFlowsOnShutdown() async {
        let persistence = makePersistence()
        let flowId = UUID()
        let t0 = Date()

        // Send a large intermediate flow that is not persisted initially
        let largeBody = Data(repeating: 0x44, count: 600 * 1024)
        let intermediate = makeFlow(id: flowId, responseBody: largeBody, isCompleted: false)
        let persisted = await persistence.persist(intermediate, now: t0)
        XCTAssertFalse(persisted)

        // Session log should be empty before flush
        XCTAssertEqual(SessionLog.read(url: sessionLogURL).count, 0)

        // Flush on shutdown
        await persistence.flush()

        // Session log should now contain the in-flight flow snapshot
        let flows = SessionLog.read(url: sessionLogURL)
        XCTAssertEqual(flows.count, 1)
        XCTAssertEqual(flows.first?.id, flowId)
    }

    func testDrainAndClearRemovesSpoolFilesAndStopsFurtherWrites() async {
        let persistence = makePersistence()
        let flow = makeFlow(path: "/active", isCompleted: true)
        let persisted = await persistence.persist(flow)
        XCTAssertTrue(persisted)

        // Spool has file
        let spoolFilesBefore = (try? FileManager.default.contentsOfDirectory(atPath: spoolDirectory.path)) ?? []
        XCTAssertFalse(spoolFilesBefore.isEmpty)

        // Drain and clear
        await persistence.drainAndClear()

        // Spool must be empty
        let spoolFilesAfter = (try? FileManager.default.contentsOfDirectory(atPath: spoolDirectory.path)) ?? []
        XCTAssertTrue(spoolFilesAfter.isEmpty)

        // Any writes after drainAndClear must be dropped (no race condition)
        let lateFlow = makeFlow(path: "/late", isCompleted: true)
        let latePersisted = await persistence.persist(lateFlow)
        XCTAssertFalse(latePersisted, "Writes after drainAndClear must be dropped")

        let spoolFilesLate = (try? FileManager.default.contentsOfDirectory(atPath: spoolDirectory.path)) ?? []
        XCTAssertTrue(spoolFilesLate.isEmpty)
    }

    func testResetSynchronouslyClearsSpoolAndSessionLog() async {
        let persistence = makePersistence()
        let flow = makeFlow(path: "/initial", isCompleted: true)
        await persistence.persist(flow)

        XCTAssertEqual(SessionLog.read(url: sessionLogURL).count, 1)
        XCTAssertFalse(FlowSpool.pendingURLs(directory: spoolDirectory).isEmpty)

        persistence.resetSynchronously()

        XCTAssertEqual(SessionLog.read(url: sessionLogURL).count, 0)
        XCTAssertTrue(FlowSpool.pendingURLs(directory: spoolDirectory).isEmpty)
    }

    func testSessionLogReaderAndSpoolReaderCompatibility() async {
        let persistence = makePersistence()
        let flow = makeFlow(path: "/reader-test", responseBody: Data("hello world".utf8), isCompleted: true)
        await persistence.persist(flow)

        // Check SessionLog.read
        let sessionFlows = SessionLog.read(url: sessionLogURL)
        XCTAssertEqual(sessionFlows.count, 1)
        XCTAssertEqual(sessionFlows.first?.request.path, "/reader-test")
        XCTAssertEqual(sessionFlows.first?.response?.body, Data("hello world".utf8))

        // Check FlowSpool.read
        let urls = FlowSpool.pendingURLs(directory: spoolDirectory)
        XCTAssertEqual(urls.count, 1)
        if let firstURL = urls.first {
            let spoolFlow = FlowSpool.read(firstURL)
            XCTAssertNotNil(spoolFlow)
            XCTAssertEqual(spoolFlow?.request.path, "/reader-test")
            XCTAssertEqual(spoolFlow?.response?.body, Data("hello world".utf8))
        }
    }
}
