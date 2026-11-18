import Foundation
import Combine

/// Observable, ordered collection of captured flows.
///
/// All mutation happens on the main actor so SwiftUI can bind directly. The
/// proxy engine emits snapshots (see `Flow`) which are upserted here by id.
///
/// `flows` is deliberately not a `@Published` property. A busy proxy emits several
/// snapshots per flow (request, response head, throttled body, completion), and
/// re-publishing each one would redraw the traffic table on every batch. Instead
/// `revision` is bumped at most once per `publishInterval`, so observers coalesce a
/// burst into a single redraw while `flows` stays immediately readable.
@MainActor
public final class FlowStore: ObservableObject {
    public private(set) var flows: [Flow] = []
    @Published public var selectedFlowID: UUID?
    @Published public private(set) var isCapturing: Bool = false

    /// Bumped whenever `flows` changes, coalesced to `publishInterval`. Views observe
    /// the store and redraw off this signal rather than once per upsert.
    @Published public private(set) var revision: Int = 0

    /// Maximum retained flows. Oldest are evicted first once exceeded.
    public var maxFlows: Int = 20_000

    /// Soft cap on retained body bytes across all flows. Defaults to 256 MiB.
    public var maxBytes: Int = 256 * 1024 * 1024

    /// Total payload bytes of currently retained flows.
    public private(set) var totalPayloadBytes: Int = 0

    /// Shortest gap between `revision` bumps. Adaptive to flow volume: 100 ms normally,
    /// 250 ms above 5k flows. Setting a custom value overrides the adaptive behavior.
    public var publishInterval: Duration {
        get {
            if let customPublishInterval {
                return customPublishInterval
            }
            return flows.count > 5_000 ? .milliseconds(250) : .milliseconds(100)
        }
        set {
            customPublishInterval = newValue
        }
    }

    private var customPublishInterval: Duration?
    private var indexByID: [UUID: Int] = [:]
    private var pinnedIDs: Set<UUID> = []
    private var publishScheduled = false
    private var publishTask: Task<Void, Never>?

    public init() {}

    public var selectedFlow: Flow? {
        guard let selectedFlowID, let index = indexByID[selectedFlowID] else { return nil }
        return flows[index]
    }

    public func setCapturing(_ value: Bool) {
        isCapturing = value
    }

    /// Reset any custom publish interval back to the default adaptive behavior.
    public func resetPublishInterval() {
        customPublishInterval = nil
    }

    /// Pin a flow by id so it survives eviction.
    public func pin(_ id: UUID) {
        pinnedIDs.insert(id)
        if let index = indexByID[id] {
            flows[index].isPinned = true
        }
        publishNow()
    }

    /// Unpin a flow by id.
    public func unpin(_ id: UUID) {
        pinnedIDs.remove(id)
        if let index = indexByID[id] {
            flows[index].isPinned = false
        }
        evictIfNeeded()
        publishNow()
    }

    /// Pin multiple flows by id.
    public func pin(ids: Set<UUID>) {
        pinnedIDs.formUnion(ids)
        for id in ids {
            if let index = indexByID[id] {
                flows[index].isPinned = true
            }
        }
        publishNow()
    }

    /// Unpin multiple flows by id.
    public func unpin(ids: Set<UUID>) {
        pinnedIDs.subtract(ids)
        for id in ids {
            if let index = indexByID[id] {
                flows[index].isPinned = false
            }
        }
        evictIfNeeded()
        publishNow()
    }

    /// Whether a flow is currently pinned.
    public func isPinned(_ id: UUID) -> Bool {
        pinnedIDs.contains(id)
    }

    /// Set the pinned state for a flow id.
    public func setPinned(_ isPinned: Bool, for id: UUID) {
        if isPinned {
            pin(id)
        } else {
            unpin(id)
        }
    }

    /// The set of all currently pinned flow IDs.
    public var pinnedIDsSet: Set<UUID> {
        pinnedIDs
    }

    /// Insert or replace a batch of flows, preserving position for updates.
    public func upsert(_ flows: [Flow]) {
        guard !flows.isEmpty else { return }

        for flow in flows {
            if flow.isPinned {
                pinnedIDs.insert(flow.id)
            }
            var toInsert = flow
            if let index = indexByID[toInsert.id] {
                totalPayloadBytes -= self.flows[index].payloadBytes
                let currentRev = self.flows[index].revision ?? 0
                if (toInsert.revision ?? 0) <= currentRev {
                    toInsert.revision = currentRev &+ 1
                }
                self.flows[index] = toInsert
                totalPayloadBytes += toInsert.payloadBytes
            } else {
                if toInsert.revision == nil {
                    toInsert.revision = 0
                }
                indexByID[toInsert.id] = self.flows.count
                self.flows.append(toInsert)
                totalPayloadBytes += toInsert.payloadBytes
            }
        }

        evictIfNeeded()

        // Label before publishing: the sidebar and filter read it from the same batch.
        for flow in flows {
            if let device = flow.connectedDevice {
                DeviceAttribution.record(device, for: flow.id)
            }
        }

        schedulePublish()
    }

    /// Insert or replace a flow, preserving position for updates.
    public func upsert(_ flow: Flow) {
        upsert([flow])
    }

    public func clear() {
        flows.removeAll()
        indexByID.removeAll()
        pinnedIDs.removeAll()
        totalPayloadBytes = 0
        selectedFlowID = nil
        DecodedBodyCache.shared.clear()
        publishNow()
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        for id in ids {
            if let index = indexByID[id] {
                totalPayloadBytes -= flows[index].payloadBytes
            }
        }
        flows.removeAll { ids.contains($0.id) }
        rebuildIndex()
        publishNow()
    }

    public func flow(withID id: UUID) -> Flow? {
        indexByID[id].map { flows[$0] }
    }

    /// Coalesce a burst of mutations into a single redraw.
    private func schedulePublish() {
        guard !publishScheduled else { return }
        publishScheduled = true
        let interval = publishInterval
        publishTask = Task { @MainActor [weak self] in
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.publishScheduled = false
            self.publishTask = nil
            self.revision &+= 1
        }
    }

    /// Publish at once, for user actions that must not wait out the interval.
    public func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        publishScheduled = false
        revision &+= 1
    }

    private func evictIfNeeded() {
        guard flows.count > maxFlows || totalPayloadBytes > maxBytes else { return }

        let chunkSize = max(64, maxFlows / 20)
        let countOverflow = flows.count > maxFlows ? flows.count - maxFlows : 0
        let targetCountToRemove = countOverflow > 0 ? min(max(0, flows.count - 1), countOverflow + chunkSize) : 0

        var removeIndices = Set<Int>()
        var removedCount = 0
        var currentBytes = totalPayloadBytes

        for (idx, flow) in flows.enumerated() {
            guard !pinnedIDs.contains(flow.id) else { continue }
            let needsCountEviction = removedCount < targetCountToRemove
            let needsByteEviction = currentBytes > maxBytes

            guard needsCountEviction || needsByteEviction else { break }
            // Never evict if only 1 unpinned flow remains and no pinned flows exist,
            // so a single oversized response does not leave the traffic list blank.
            if (flows.count - removeIndices.count) <= 1 { break }

            removeIndices.insert(idx)
            removedCount += 1
            currentBytes -= flow.payloadBytes
        }

        if !removeIndices.isEmpty {
            flows = flows.enumerated().compactMap { idx, flow in
                removeIndices.contains(idx) ? nil : flow
            }
            totalPayloadBytes = currentBytes
            rebuildIndex()
        }
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (offset, flow) in flows.enumerated() {
            indexByID[flow.id] = offset
        }
    }
}
