import XCTest
@testable import FlowKit

final class CaptureMetricsTests: XCTestCase {
    func testEnqueueAndHandleTrackTheBacklog() {
        let metrics = CaptureMetrics(subsystem: "test.capture.enqueue")

        metrics.recordSnapshotEnqueued()
        metrics.recordSnapshotEnqueued()
        XCTAssertEqual(metrics.snapshot().pendingSnapshots, 2)
        XCTAssertEqual(metrics.snapshot().snapshotsEnqueued, 2)

        metrics.recordSnapshotHandled(flowCount: 7)
        var counters = metrics.snapshot()
        XCTAssertEqual(counters.pendingSnapshots, 1)
        XCTAssertEqual(counters.snapshotsIngested, 1)
        XCTAssertEqual(counters.flowCount, 7)
    }

    func testHandlingWithoutAnEnqueueDoesNotDrivePendingNegative() {
        let metrics = CaptureMetrics(subsystem: "test.capture.negative")

        metrics.recordSnapshotHandled(flowCount: 1)
        XCTAssertEqual(metrics.snapshot().pendingSnapshots, 0)
    }

    func testIngestDrainCountsSnapshotsAndDrains() {
        let metrics = CaptureMetrics(subsystem: "test.capture.drain")

        metrics.recordIngestDrain(snapshots: 4, flowCount: 3)
        metrics.recordIngestDrain(snapshots: 0, flowCount: 3)

        let counters = metrics.snapshot()
        XCTAssertEqual(counters.ingestDrains, 2)
        XCTAssertEqual(counters.snapshotsIngested, 4)
        XCTAssertEqual(counters.pendingSnapshots, 0)
        XCTAssertEqual(counters.flowCount, 3)
    }

    func testDroppedSnapshotsLeaveTheBacklog() {
        let metrics = CaptureMetrics(subsystem: "test.capture.drops")

        metrics.recordSnapshotEnqueued()
        metrics.recordSnapshotEnqueued()
        metrics.recordSnapshotEnqueued()
        metrics.recordDroppedSnapshots(2)

        let counters = metrics.snapshot()
        XCTAssertEqual(counters.droppedSnapshots, 2)
        XCTAssertEqual(counters.pendingSnapshots, 1)
    }

    func testDroppingMoreThanIsPendingStopsAtZero() {
        let metrics = CaptureMetrics(subsystem: "test.capture.overdrop")

        metrics.recordSnapshotEnqueued()
        metrics.recordDroppedSnapshots(5)

        XCTAssertEqual(metrics.snapshot().pendingSnapshots, 0)
        XCTAssertEqual(metrics.snapshot().droppedSnapshots, 5)
    }

    func testPersistenceWritesAndListDerivationsCount() {
        let metrics = CaptureMetrics(subsystem: "test.capture.writes")

        metrics.recordPersistenceWrites(2)
        metrics.recordListDerivation()
        metrics.recordListDerivation()

        let counters = metrics.snapshot()
        XCTAssertEqual(counters.persistenceWrites, 2)
        XCTAssertEqual(counters.listDerivations, 2)
    }

    func testIntervalReturnsTheBodyValueAndClosesOnThrow() {
        let metrics = CaptureMetrics(subsystem: "test.capture.interval")

        let value = metrics.interval(CaptureSignposts.ingestUpsert) { 42 }
        XCTAssertEqual(value, 42)

        struct Boom: Error {}
        XCTAssertThrowsError(try metrics.interval(CaptureSignposts.persistenceWrite) { throw Boom() })
    }

    func testResetClearsEveryCounter() {
        let metrics = CaptureMetrics(subsystem: "test.capture.reset")

        metrics.recordSnapshotEnqueued()
        metrics.recordSnapshotHandled(flowCount: 2)
        metrics.recordDroppedSnapshots()
        metrics.recordPersistenceWrites(3)
        metrics.recordIngestDrain(snapshots: 1, flowCount: 2)
        metrics.recordListDerivation()

        metrics.reset()

        XCTAssertEqual(metrics.snapshot(), CaptureMetrics.Counters())
    }

    func testConcurrentEnqueuesAreAllCounted() {
        let metrics = CaptureMetrics(subsystem: "test.capture.concurrent")
        let count = 500

        DispatchQueue.concurrentPerform(iterations: count) { _ in
            metrics.recordSnapshotEnqueued()
        }

        let counters = metrics.snapshot()
        XCTAssertEqual(counters.snapshotsEnqueued, UInt64(count))
        XCTAssertEqual(counters.pendingSnapshots, count)
    }
}
