import Foundation

/// Thread-safe handoff buffer that collects and coalesces flow snapshots emitted by
/// the proxy engine's NIO threads before they are drained and upserted in batches.
///
/// Under high throughput or continuous streaming responses (e.g. MJPEG / CCTV),
/// interim snapshots for the same flow arrive rapidly. This buffer coalesces snapshots
/// by `Flow.id` so only the latest state is retained, preserves first-seen capture
/// order, bounds the active flow count, and drops the oldest in-flight flows when
/// overflowing while never dropping completed snapshots.
public final class FlowIngestBuffer: @unchecked Sendable {
    /// A drained batch of coalesced flows and their represented snapshot count.
    public struct Batch: Sendable {
        public let flows: [Flow]
        public let snapshotCount: Int

        public init(flows: [Flow], snapshotCount: Int) {
            self.flows = flows
            self.snapshotCount = snapshotCount
        }

        public var isEmpty: Bool { flows.isEmpty }
    }

    private struct Entry {
        var flow: Flow
        var snapshotCount: Int
    }

    public let capacity: Int
    private let metrics: CaptureMetrics?
    private let lock = NSLock()

    private var flows: [UUID: Entry] = [:]
    private var order: [UUID] = []
    private var inFlightCount: Int = 0
    private var totalPendingSnapshots: Int = 0
    private var _droppedCount: UInt64 = 0

    public init(capacity: Int = 10_000, metrics: CaptureMetrics? = .shared) {
        self.capacity = max(1, capacity)
        self.metrics = metrics
    }

    /// Number of distinct flows currently held in the buffer.
    public var count: Int {
        lock.lock(); defer { lock.unlock() }
        return flows.count
    }

    /// True if no flows are currently buffered.
    public var isEmpty: Bool {
        lock.lock(); defer { lock.unlock() }
        return flows.isEmpty
    }

    /// Total number of snapshots dropped due to buffer overflow.
    public var droppedCount: UInt64 {
        lock.lock(); defer { lock.unlock() }
        return _droppedCount
    }

    /// Total number of enqueued snapshots represented by the buffered flows.
    public var pendingSnapshots: Int {
        lock.lock(); defer { lock.unlock() }
        return totalPendingSnapshots
    }

    /// Enqueue a flow snapshot from the engine callback.
    ///
    /// If a snapshot for `flow.id` is already pending in the buffer, it is updated in place
    /// with the latest snapshot while preserving its first-seen position.
    /// If the buffer is at capacity, the oldest in-flight flow is dropped to make room.
    /// Completed snapshots are never dropped.
    public func enqueue(_ flow: Flow) {
        lock.lock(); defer { lock.unlock() }

        if var existing = flows[flow.id] {
            let wasInFlight = !existing.flow.isCompleted
            let isInFlight = !flow.isCompleted
            if wasInFlight && !isInFlight {
                inFlightCount -= 1
            } else if !wasInFlight && isInFlight {
                inFlightCount += 1
            }
            existing.flow = flow
            existing.snapshotCount += 1
            flows[flow.id] = existing
            totalPendingSnapshots += 1
            return
        }

        if flows.count >= capacity {
            if inFlightCount > 0, let victimIndex = order.firstIndex(where: { id in
                guard let entry = flows[id] else { return false }
                return !entry.flow.isCompleted
            }) {
                let victimID = order.remove(at: victimIndex)
                if let victim = flows.removeValue(forKey: victimID) {
                    inFlightCount -= 1
                    totalPendingSnapshots -= victim.snapshotCount
                    _droppedCount &+= UInt64(victim.snapshotCount)
                    metrics?.recordDroppedSnapshots(victim.snapshotCount)
                }

                let isFlowInFlight = !flow.isCompleted
                if isFlowInFlight { inFlightCount += 1 }
                flows[flow.id] = Entry(flow: flow, snapshotCount: 1)
                order.append(flow.id)
                totalPendingSnapshots += 1
            } else {
                // All entries currently in the buffer are completed.
                if flow.isCompleted {
                    // Completed snapshots are never dropped.
                    flows[flow.id] = Entry(flow: flow, snapshotCount: 1)
                    order.append(flow.id)
                    totalPendingSnapshots += 1
                } else {
                    // Incoming flow is in-flight and cannot evict completed snapshots.
                    _droppedCount &+= 1
                    metrics?.recordDroppedSnapshots(1)
                }
            }
        } else {
            let isFlowInFlight = !flow.isCompleted
            if isFlowInFlight { inFlightCount += 1 }
            flows[flow.id] = Entry(flow: flow, snapshotCount: 1)
            order.append(flow.id)
            totalPendingSnapshots += 1
        }
    }

    /// Drain up to `maxCount` flows in first-seen order.
    public func drain(maxCount: Int = 500) -> Batch {
        lock.lock(); defer { lock.unlock() }
        guard !order.isEmpty else {
            return Batch(flows: [], snapshotCount: 0)
        }

        let countToTake = min(max(1, maxCount), order.count)
        let batchIDs = Array(order.prefix(countToTake))
        order.removeFirst(countToTake)

        var batchFlows: [Flow] = []
        batchFlows.reserveCapacity(countToTake)
        var batchSnapshots = 0

        for id in batchIDs {
            guard let entry = flows.removeValue(forKey: id) else { continue }
            if !entry.flow.isCompleted {
                inFlightCount -= 1
            }
            batchFlows.append(entry.flow)
            batchSnapshots += entry.snapshotCount
        }

        totalPendingSnapshots = max(0, totalPendingSnapshots - batchSnapshots)
        return Batch(flows: batchFlows, snapshotCount: batchSnapshots)
    }

    /// Drain all buffered flows in first-seen order.
    public func drainAll() -> Batch {
        drain(maxCount: Int.max)
    }

    /// Clear all flows and reset counters without changing the dropped count.
    public func clear() {
        lock.lock(); defer { lock.unlock() }
        flows.removeAll()
        order.removeAll()
        inFlightCount = 0
        totalPendingSnapshots = 0
    }
}
