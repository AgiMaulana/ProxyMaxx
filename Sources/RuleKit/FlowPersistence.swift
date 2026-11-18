import Foundation
import FlowKit

/// Rules and intervals governing persistence throttling for intermediate flow snapshots.
///
/// Under high throughput or continuous streaming responses (e.g. CCTV / MJPEG),
/// intermediate body updates arrive at high frequency. Persisting every intermediate
/// snapshot to the spool and session log causes severe disk I/O and JSON serialization
/// churn. Intermediate snapshots are throttled based on body size and streaming status,
/// while terminal (completed or failed) snapshots are always persisted immediately.
public enum FlowPersistenceThrottle {
    /// Responses smaller than this cap persist intermediate snapshots at up to 2 Hz (500 ms).
    public static let smallBodyThreshold = 128 * 1024
    /// Responses between 128 KiB and 512 KiB persist intermediate snapshots at up to 1 Hz (1 s).
    public static let mediumBodyThreshold = 512 * 1024

    /// Minimum interval between intermediate persistence writes for small bodies (< 128 KiB).
    public static let smallBodyInterval: TimeInterval = 0.5
    /// Minimum interval between intermediate persistence writes for medium bodies (< 512 KiB).
    public static let mediumBodyInterval: TimeInterval = 1.0

    /// Evaluates whether a snapshot should be persisted to disk at the given time.
    public static func shouldPersist(
        flow: Flow,
        lastPersistedAt: Date?,
        now: Date = Date()
    ) -> Bool {
        // Terminal snapshots (completion or error) must always be persisted.
        if flow.isCompleted {
            return true
        }

        let bodyBytes = max(flow.requestBytes, flow.responseBytes)

        // Large bodies (>= 512 KiB) and streaming responses persist final snapshots only.
        if flow.isStreaming || flow.isStreamingResponse == true || bodyBytes >= mediumBodyThreshold {
            return false
        }

        // Medium bodies (< 512 KiB): 1.0 s throttle interval.
        if bodyBytes >= smallBodyThreshold {
            guard let last = lastPersistedAt else { return true }
            return now.timeIntervalSince(last) >= mediumBodyInterval
        }

        // Small bodies (< 128 KiB): 0.5 s (500 ms) throttle interval.
        guard let last = lastPersistedAt else { return true }
        return now.timeIntervalSince(last) >= smallBodyInterval
    }
}

/// Actor owning `FlowSpool.Writer` and `SessionLog.Writer`, providing serialized,
/// background, throttled persistence for captured flows.
///
/// Throttles intermediate body snapshots to prevent disk/JSON saturation under streaming
/// traffic (such as CCTV / MJPEG), while guaranteeing every final snapshot is persisted.
/// Serializing writes through this actor off the main actor also guarantees that
/// `clear()` or `reset()` never races with pending persistence writes.
public actor FlowPersistence {
    nonisolated public let spool: FlowSpool.Writer
    nonisolated public let sessionLog: SessionLog.Writer
    private let metrics: CaptureMetrics?

    private var isStopped = false
    /// Last time an intermediate or initial snapshot was persisted for each flow ID.
    private var lastPersistedAt: [UUID: Date] = [:]
    /// In-flight flows that have not yet reached completion or error.
    private var inFlightFlows: [UUID: Flow] = [:]
    /// Order in which in-flight flows were first seen.
    private var inFlightOrder: [UUID] = []

    public init(
        spool: FlowSpool.Writer = FlowSpool.Writer(),
        sessionLog: SessionLog.Writer = SessionLog.Writer(),
        metrics: CaptureMetrics? = .shared
    ) {
        self.spool = spool
        self.sessionLog = sessionLog
        self.metrics = metrics
    }

    /// Reset internal tracking and underlying spool and session log storage.
    public func reset() {
        isStopped = false
        lastPersistedAt.removeAll()
        inFlightFlows.removeAll()
        inFlightOrder.removeAll()
        spool.reset()
        sessionLog.reset()
    }

    /// Nonisolated synchronous reset for startup paths that need synchronous initialization.
    nonisolated public func resetSynchronously() {
        spool.reset()
        sessionLog.reset()
    }

    /// Persist a flow snapshot if it meets the throttling rules.
    ///
    /// - Returns: `true` if the snapshot was persisted, `false` if it was throttled.
    @discardableResult
    public func persist(_ flow: Flow, now: Date = Date()) -> Bool {
        guard !isStopped else { return false }

        if flow.isCompleted {
            inFlightFlows.removeValue(forKey: flow.id)
            lastPersistedAt.removeValue(forKey: flow.id)
            inFlightOrder.removeAll(where: { $0 == flow.id })

            writeToStorage(flow)
            return true
        }

        if inFlightFlows[flow.id] == nil {
            inFlightOrder.append(flow.id)
        }
        inFlightFlows[flow.id] = flow
        let lastTime = lastPersistedAt[flow.id]

        let should = FlowPersistenceThrottle.shouldPersist(
            flow: flow,
            lastPersistedAt: lastTime,
            now: now
        )

        if should {
            lastPersistedAt[flow.id] = now
            writeToStorage(flow)
            return true
        }

        return false
    }

    /// Persist multiple flow snapshots sequentially.
    ///
    /// - Returns: Total count of snapshots persisted.
    @discardableResult
    public func persist(_ flows: [Flow], now: Date = Date()) -> Int {
        var persistedCount = 0
        for flow in flows {
            if persist(flow, now: now) {
                persistedCount += 1
            }
        }
        return persistedCount
    }

    /// Flush any remaining in-flight flows to storage upon shutdown so intermediate
    /// snapshots for still-open flows are preserved.
    public func flush() {
        let flows = inFlightOrder.compactMap { inFlightFlows[$0] }
        inFlightFlows.removeAll()
        inFlightOrder.removeAll()
        lastPersistedAt.removeAll()

        for flow in flows {
            writeToStorage(flow)
        }
        sessionLog.flush()
    }

    /// Clear persisted spool files and in-memory tracking.
    public func clear() {
        isStopped = true
        inFlightFlows.removeAll()
        inFlightOrder.removeAll()
        lastPersistedAt.removeAll()
        spool.clear()
        sessionLog.close()
    }

    /// Drain pending writes, flush in-flight flows to session log, and clear spool files.
    public func drainAndClear() {
        isStopped = true
        flush()
        clear()
    }

    /// Nonisolated synchronous clear for `defer` blocks or exit handlers.
    nonisolated public func clearSynchronously() {
        spool.clear()
        sessionLog.close()
    }

    private func writeToStorage(_ flow: Flow) {
        if let metrics {
            metrics.interval(CaptureSignposts.persistenceWrite) {
                spool.write(flow)
                sessionLog.append(flow)
            }
            metrics.recordPersistenceWrites(1)
        } else {
            spool.write(flow)
            sessionLog.append(flow)
        }
    }
}
