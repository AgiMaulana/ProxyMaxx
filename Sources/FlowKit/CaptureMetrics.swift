import Foundation
import os

/// Names of the `os_signpost` intervals the capture pipeline emits.
///
/// The names are the contract with Instruments: a saved trace or a `log stream
/// --signpost` capture keeps them, so a baseline recorded now can be compared with a
/// later phase that moves work off the main actor (issue #58).
public enum CaptureSignposts {
    /// One engine snapshot handed from the NIO thread to the main actor.
    public static let snapshotEnqueue: StaticString = "snapshot.enqueue"
    /// One pass over the shared spool while attached to another front-end's engine.
    public static let ingestDrain: StaticString = "ingest.drain"
    /// One batch of snapshots upserted into `FlowStore`.
    public static let ingestUpsert: StaticString = "ingest.upsert"
    /// One spool write plus session-log append.
    public static let persistenceWrite: StaticString = "persistence.write"
    /// One recomputation of the traffic list and its sidebar summary.
    public static let listDerive: StaticString = "list.derive"
    /// One or more snapshots refused by a bounded stage.
    public static let snapshotDropped: StaticString = "snapshot.dropped"
}

/// Counters and signposts for the capture path.
///
/// This is measurement only. A busy proxy can deliver several snapshots per millisecond
/// while the main actor is also encoding each one for the spool and the session log, so
/// the fix for the hang (issue #58) has to start from a recorded baseline rather than a
/// guess. Every stage reports here — enqueue on the engine's thread, the main-actor
/// drain, the store upsert, and the persistence write — and the counters double as the
/// health signal the 5 s backlog report reads.
///
/// Counting is cheap enough to leave on in a release build: one lock per event on a path
/// that already takes a lock in `FlowRecorder` and does JSON encoding. The signposts are
/// free until something is recording them.
public final class CaptureMetrics: @unchecked Sendable {
    /// Process-wide instance: the engine callback, the app model, and the CLI can report
    /// into the same counters without threading an object through every layer.
    public static let shared = CaptureMetrics()

    /// Everything an observer needs to describe the capture path in one reading.
    public struct Counters: Equatable, Sendable {
        /// Snapshots the engine handed over, whether or not they were handled yet.
        public var snapshotsEnqueued: UInt64 = 0
        /// Snapshots that reached the store, whether from the local engine or the spool.
        public var snapshotsIngested: UInt64 = 0
        /// Enqueued but not yet handled: the backlog that makes the UI slow.
        public var pendingSnapshots: Int = 0
        /// Snapshots a bounded stage refused, so a burst cannot grow without limit.
        public var droppedSnapshots: UInt64 = 0
        /// Spool or session-log writes performed.
        public var persistenceWrites: UInt64 = 0
        /// Spool drains performed while attached to another front-end's engine.
        public var ingestDrains: UInt64 = 0
        /// Traffic-list derivations triggered by the UI.
        public var listDerivations: UInt64 = 0
        /// Rows currently retained, as last reported by the store.
        public var flowCount: Int = 0
    }

    private let signposter: OSSignposter
    private let lock = NSLock()
    private var counters = Counters()

    public init(subsystem: String = "oss.proxymaxx", category: String = "capture") {
        signposter = OSSignposter(subsystem: subsystem, category: category)
    }

    // MARK: - Signposts

    /// Measure one interval. The name is the one Instruments shows, and the state is
    /// closed on every exit path, so a throwing body still ends its interval.
    @discardableResult
    public func interval<T>(_ name: StaticString, _ body: () throws -> T) rethrows -> T {
        let state = signposter.beginInterval(name)
        defer { signposter.endInterval(name, state) }
        return try body()
    }

    /// Mark an instant that is not an interval, for events that have no duration.
    public func event(_ name: StaticString) {
        signposter.emitEvent(name)
    }

    // MARK: - Counters

    /// The engine handed over one snapshot, before any main-actor work.
    public func recordSnapshotEnqueued() {
        lock.lock(); defer { lock.unlock() }
        counters.snapshotsEnqueued &+= 1
        counters.pendingSnapshots += 1
    }

    /// One or more enqueued snapshots were upserted and persisted by the main actor.
    public func recordSnapshotHandled(count: Int = 1, flowCount: Int) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        counters.snapshotsIngested &+= UInt64(count)
        counters.pendingSnapshots = max(0, counters.pendingSnapshots - count)
        counters.flowCount = flowCount
    }

    /// A spool drain finished, having read `snapshots` files. Draining does not go
    /// through the enqueue path, so only the ingest side moves here.
    public func recordIngestDrain(snapshots: Int, flowCount: Int) {
        lock.lock(); defer { lock.unlock() }
        counters.ingestDrains &+= 1
        if snapshots > 0 { counters.snapshotsIngested &+= UInt64(snapshots) }
        counters.flowCount = flowCount
    }

    /// A spool or session-log write completed.
    public func recordPersistenceWrites(_ count: Int = 1) {
        guard count > 0 else { return }
        lock.lock(); defer { lock.unlock() }
        counters.persistenceWrites &+= UInt64(count)
    }

    /// A bounded stage discarded enqueued snapshots, so they will never be handled.
    public func recordDroppedSnapshots(_ count: Int = 1) {
        guard count > 0 else { return }
        event(CaptureSignposts.snapshotDropped)
        lock.lock(); defer { lock.unlock() }
        counters.droppedSnapshots &+= UInt64(count)
        counters.pendingSnapshots = max(0, counters.pendingSnapshots - count)
    }

    /// The UI recomputed the traffic list. Reported without a count of rows because the
    /// cost is the derivation, and the row count is already in `flowCount`.
    public func recordListDerivation() {
        lock.lock(); defer { lock.unlock() }
        counters.listDerivations &+= 1
    }

    public func updateFlowCount(_ count: Int) {
        lock.lock(); defer { lock.unlock() }
        counters.flowCount = count
    }

    /// One consistent reading, safe to take from any thread.
    public func snapshot() -> Counters {
        lock.lock(); defer { lock.unlock() }
        return counters
    }

    /// Drop every counter without replacing the signposter, for a fresh session or a test.
    public func reset() {
        lock.lock(); defer { lock.unlock() }
        counters = Counters()
    }
}
