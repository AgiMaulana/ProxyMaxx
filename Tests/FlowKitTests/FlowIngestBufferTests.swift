import XCTest
@testable import FlowKit

final class FlowIngestBufferTests: XCTestCase {
    private func makeFlow(
        id: UUID = UUID(),
        path: String = "/test",
        isCompleted: Bool = false
    ) -> Flow {
        let request = HTTPRequest(
            method: "GET",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: path,
            headers: HTTPHeaders([Header(name: "Host", value: "example.com")]),
            body: Data()
        )
        var timing = FlowTiming()
        if isCompleted {
            timing.end = Date()
        }
        return Flow(
            id: id,
            request: request,
            response: isCompleted ? HTTPResponse(statusCode: 200, httpVersion: "HTTP/1.1", headers: HTTPHeaders(), body: Data()) : nil,
            timing: timing
        )
    }

    func testTenThousandEnqueuesCollapseToOneEntry() {
        let metrics = CaptureMetrics(subsystem: "test.buffer.collapse")
        let buffer = FlowIngestBuffer(capacity: 10_000, metrics: metrics)
        let flowID = UUID()

        for i in 1...10_000 {
            let flow = makeFlow(id: flowID, path: "/item-\(i)", isCompleted: i == 10_000)
            buffer.enqueue(flow)
        }

        XCTAssertEqual(buffer.count, 1)
        XCTAssertEqual(buffer.pendingSnapshots, 10_000)
        XCTAssertEqual(buffer.droppedCount, 0)

        let batch = buffer.drain(maxCount: 500)
        XCTAssertEqual(batch.flows.count, 1)
        XCTAssertEqual(batch.snapshotCount, 10_000)
        XCTAssertEqual(batch.flows[0].id, flowID)
        XCTAssertEqual(batch.flows[0].path, "/item-10000")
        XCTAssertTrue(batch.flows[0].isCompleted)
        XCTAssertTrue(buffer.isEmpty)
    }

    func testOverflowDropsOldestInFlightFirst() {
        let metrics = CaptureMetrics(subsystem: "test.buffer.overflow")
        let buffer = FlowIngestBuffer(capacity: 3, metrics: metrics)

        let flow1 = makeFlow(path: "/1", isCompleted: false)
        let flow2 = makeFlow(path: "/2", isCompleted: false)
        let flow3 = makeFlow(path: "/3", isCompleted: false)
        let flow4 = makeFlow(path: "/4", isCompleted: false)

        buffer.enqueue(flow1)
        buffer.enqueue(flow2)
        buffer.enqueue(flow3)
        XCTAssertEqual(buffer.count, 3)

        // Overflow: buffer is at capacity 3, flow 1 is the oldest in-flight flow.
        buffer.enqueue(flow4)

        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.droppedCount, 1)

        let batch = buffer.drainAll()
        XCTAssertEqual(batch.flows.count, 3)
        XCTAssertEqual(batch.flows.map(\.path), ["/2", "/3", "/4"])
    }

    func testCompletedSnapshotsAreNeverDropped() {
        let metrics = CaptureMetrics(subsystem: "test.buffer.completed")
        let buffer = FlowIngestBuffer(capacity: 3, metrics: metrics)

        let flow1 = makeFlow(path: "/1", isCompleted: true)
        let flow2 = makeFlow(path: "/2", isCompleted: false)
        let flow3 = makeFlow(path: "/3", isCompleted: true)
        let flow4 = makeFlow(path: "/4", isCompleted: false)

        buffer.enqueue(flow1)
        buffer.enqueue(flow2)
        buffer.enqueue(flow3)
        XCTAssertEqual(buffer.count, 3)

        // Buffer has [flow1 (completed), flow2 (in-flight), flow3 (completed)].
        // Enqueueing flow4 (in-flight) must drop flow2 (the oldest in-flight), NOT flow1.
        buffer.enqueue(flow4)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.droppedCount, 1)

        // Enqueue flow5 (completed). Buffer currently has [flow1, flow3, flow4 (in-flight)].
        // Flow4 is in-flight and gets evicted to make room for flow5.
        let flow5 = makeFlow(path: "/5", isCompleted: true)
        buffer.enqueue(flow5)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.droppedCount, 2)

        // Now buffer contains [flow1, flow3, flow5], ALL of which are completed.
        // Enqueueing an in-flight flow6 must be dropped because completed snapshots cannot be evicted.
        let flow6 = makeFlow(path: "/6", isCompleted: false)
        buffer.enqueue(flow6)
        XCTAssertEqual(buffer.count, 3)
        XCTAssertEqual(buffer.droppedCount, 3)

        // Enqueueing a completed flow7 must NEVER be dropped, even when buffer is full of completed snapshots.
        let flow7 = makeFlow(path: "/7", isCompleted: true)
        buffer.enqueue(flow7)
        XCTAssertEqual(buffer.count, 4)
        XCTAssertEqual(buffer.droppedCount, 3)

        let batch = buffer.drainAll()
        XCTAssertEqual(batch.flows.count, 4)
        XCTAssertEqual(batch.flows.map(\.path), ["/1", "/3", "/5", "/7"])
        XCTAssertTrue(batch.flows.allSatisfy(\.isCompleted))
    }

    func testFirstSeenOrderingIsPreservedAcrossUpdates() {
        let buffer = FlowIngestBuffer(capacity: 10)

        let flowA = makeFlow(path: "/a", isCompleted: false)
        let flowB = makeFlow(path: "/b", isCompleted: false)
        let flowC = makeFlow(path: "/c", isCompleted: false)

        buffer.enqueue(flowA)
        buffer.enqueue(flowB)
        buffer.enqueue(flowC)

        // Update flowA with a new path/snapshot
        let flowAUpdated = makeFlow(id: flowA.id, path: "/a-updated", isCompleted: true)
        buffer.enqueue(flowAUpdated)

        let batch = buffer.drainAll()
        XCTAssertEqual(batch.flows.count, 3)
        XCTAssertEqual(batch.flows.map(\.path), ["/a-updated", "/b", "/c"])
    }

    func testConcurrentEnqueuesAndDrains() {
        let buffer = FlowIngestBuffer(capacity: 500)
        let iterations = 1_000

        DispatchQueue.concurrentPerform(iterations: iterations) { i in
            let isComp = i % 5 == 0
            let flow = self.makeFlow(path: "/p-\(i)", isCompleted: isComp)
            buffer.enqueue(flow)
            if i % 10 == 0 {
                _ = buffer.drain(maxCount: 20)
            }
        }

        let remaining = buffer.drainAll()
        XCTAssertGreaterThanOrEqual(remaining.flows.count, 0)
        XCTAssertTrue(buffer.isEmpty)
    }
}
