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

    /// Shortest gap between `revision` bumps, capping redraws at 10 per second.
    public var publishInterval: Duration = .milliseconds(100)

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

    /// Insert or replace a flow, preserving position for updates.
    public func upsert(_ flow: Flow) {
        if let index = indexByID[flow.id] {
            flows[index] = flow
        } else {
            indexByID[flow.id] = flows.count
            flows.append(flow)
            evictIfNeeded()
        }
        schedulePublish()
    }

    public func clear() {
        flows.removeAll()
        indexByID.removeAll()
        pinnedIDs.removeAll()
        selectedFlowID = nil
        publishNow()
    }

    public func remove(ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
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
        publishTask = Task { @MainActor [weak self] in
            guard let interval = self?.publishInterval else { return }
            try? await Task.sleep(for: interval)
            guard let self, !Task.isCancelled else { return }
            self.publishScheduled = false
            self.publishTask = nil
            self.revision &+= 1
        }
    }

    /// Publish at once, for user actions that must not wait out the interval.
    private func publishNow() {
        publishTask?.cancel()
        publishTask = nil
        publishScheduled = false
        revision &+= 1
    }

    private func evictIfNeeded() {
        guard flows.count > maxFlows else { return }
        let overflow = flows.count - maxFlows
        var removed = 0
        flows.removeAll { flow in
            guard removed < overflow, !pinnedIDs.contains(flow.id) else { return false }
            removed += 1
            return true
        }
        rebuildIndex()
    }

    private func rebuildIndex() {
        indexByID.removeAll(keepingCapacity: true)
        for (offset, flow) in flows.enumerated() {
            indexByID[flow.id] = offset
        }
    }
}
