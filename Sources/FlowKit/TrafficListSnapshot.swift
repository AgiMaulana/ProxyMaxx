import Foundation
import Combine

/// Summary item for a client application in the sidebar.
public struct AppSummary: Identifiable, Hashable, Sendable {
    public let id: String
    public var app: ClientApp
    public var count: Int

    public init(id: String, app: ClientApp, count: Int = 0) {
        self.id = id
        self.app = app
        self.count = count
    }
}

/// Overall summary across all captured flows in one pass, independent of active filters.
public struct FlowSummary: Equatable, Sendable {
    public let total: Int
    public let apps: [AppSummary]
    public let duplicateAppNames: Set<String>
    public let domains: [String]
    private let domainCounts: [String: Int]

    public init(_ flows: [Flow]) {
        var apps: [String: AppSummary] = [:]
        var domainCounts: [String: Int] = [:]
        for flow in flows {
            if let app = flow.clientApp, flow.connectedDevice == nil {
                let id = app.id
                apps[id, default: AppSummary(id: id, app: app)].count += 1
                if apps[id]?.app.path == nil, app.path != nil {
                    apps[id]?.app = app
                }
            }
            domainCounts[flow.host, default: 0] += 1
        }
        var names: Set<String> = []
        var duplicateNames: Set<String> = []
        for entry in apps.values where !names.insert(entry.app.name).inserted {
            duplicateNames.insert(entry.app.name)
        }
        self.total = flows.count
        self.apps = apps.values.sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
        self.duplicateAppNames = duplicateNames
        self.domainCounts = domainCounts
        self.domains = domainCounts.keys.sorted()
    }

    public init(
        total: Int,
        apps: [AppSummary],
        duplicateAppNames: Set<String>,
        domains: [String],
        domainCounts: [String: Int]
    ) {
        self.total = total
        self.apps = apps
        self.duplicateAppNames = duplicateAppNames
        self.domains = domains
        self.domainCounts = domainCounts
    }

    public func domainCount(_ domain: String) -> Int { domainCounts[domain] ?? 0 }
}

/// Flows per connected device serial, counted in one pass.
public struct DeviceFlowCounts: Equatable, Sendable {
    private var counts: [String: Int] = [:]

    public init(_ flows: [Flow]) {
        for flow in flows {
            guard let serial = flow.connectedDevice?.serial else { continue }
            counts[serial, default: 0] += 1
        }
    }

    public init(counts: [String: Int] = [:]) {
        self.counts = counts
    }

    public func count(for serial: String) -> Int { counts[serial] ?? 0 }
}

/// A cached, immutable snapshot of the traffic list and sidebar counts.
public struct TrafficListSnapshot: Sendable {
    /// Filtered and scoped flows to display in the traffic table.
    public let flows: [Flow]
    /// Overall summary across all captured flows.
    public let summary: FlowSummary
    /// Flow counts grouped by connected device serial.
    public let deviceCounts: DeviceFlowCounts
    /// Flow counts for each sidebar mark entity.
    public let markCounts: [SidebarEntity: Int]
    /// Subset of flows matching pinned marks.
    public let pinnedFlows: [Flow]
    /// Subset of flows matching saved marks.
    public let savedFlows: [Flow]

    public static let empty = TrafficListSnapshot(
        flows: [],
        summary: FlowSummary([]),
        deviceCounts: DeviceFlowCounts(),
        markCounts: [:],
        pinnedFlows: [],
        savedFlows: []
    )

    public init(
        flows: [Flow],
        summary: FlowSummary,
        deviceCounts: DeviceFlowCounts,
        markCounts: [SidebarEntity: Int],
        pinnedFlows: [Flow],
        savedFlows: [Flow]
    ) {
        self.flows = flows
        self.summary = summary
        self.deviceCounts = deviceCounts
        self.markCounts = markCounts
        self.pinnedFlows = pinnedFlows
        self.savedFlows = savedFlows
    }

    public func count(for entity: SidebarEntity) -> Int {
        markCounts[entity] ?? 0
    }

    public func count(for deviceSerial: String) -> Int {
        deviceCounts.count(for: deviceSerial)
    }

    /// Computes the complete snapshot in a single linear pass over the flows.
    public static func compute(
        flows: [Flow],
        filter: FlowFilter,
        navigation: SidebarNavigation,
        pinned: [SidebarEntity],
        saved: [SidebarEntity],
        deviceSerials: [String] = []
    ) -> TrafficListSnapshot {
        guard !flows.isEmpty else {
            return .empty
        }

        var apps: [String: AppSummary] = [:]
        var domainCounts: [String: Int] = [:]
        var deviceCountsMap: [String: Int] = [:]
        var markCountsMap: [SidebarEntity: Int] = [:]
        var pinnedFlows: [Flow] = []
        var savedFlows: [Flow] = []
        var filteredFlows: [Flow] = []

        var effective = filter
        effective.sidebarSelection = navigation.flowScope
        let collection = navigation.collection

        let hasPinned = !pinned.isEmpty
        let hasSaved = !saved.isEmpty

        for flow in flows {
            // 1. Device counts
            if let device = flow.connectedDevice {
                deviceCountsMap[device.serial, default: 0] += 1
            }

            // 2. Apps summary
            if let app = flow.clientApp, flow.connectedDevice == nil {
                let id = app.id
                apps[id, default: AppSummary(id: id, app: app)].count += 1
                if apps[id]?.app.path == nil, app.path != nil {
                    apps[id]?.app = app
                }
            }

            // 3. Domain counts
            domainCounts[flow.host, default: 0] += 1

            // 4. Marks & subsets
            var isPinnedFlow = flow.isPinned
            if hasPinned {
                for entity in pinned {
                    if entity.matches(flow) {
                        markCountsMap[entity, default: 0] += 1
                        isPinnedFlow = true
                    }
                }
            }
            if isPinnedFlow {
                pinnedFlows.append(flow)
            }

            var isSavedFlow = false
            if hasSaved {
                for entity in saved {
                    if entity.matches(flow) {
                        markCountsMap[entity, default: 0] += 1
                        isSavedFlow = true
                    }
                }
            }
            if isSavedFlow {
                savedFlows.append(flow)
            }

            // 5. Filtered flows for the traffic table
            let matchesCollection: Bool
            switch collection {
            case .pinned:
                matchesCollection = isPinnedFlow
            case .saved:
                matchesCollection = isSavedFlow
            default:
                matchesCollection = true
            }

            if matchesCollection && effective.matches(flow) {
                filteredFlows.append(flow)
            }
        }

        var names: Set<String> = []
        var duplicateNames: Set<String> = []
        for entry in apps.values where !names.insert(entry.app.name).inserted {
            duplicateNames.insert(entry.app.name)
        }
        let sortedApps = apps.values.sorted {
            let order = $0.app.name.localizedStandardCompare($1.app.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }

        let summary = FlowSummary(
            total: flows.count,
            apps: sortedApps,
            duplicateAppNames: duplicateNames,
            domains: domainCounts.keys.sorted(),
            domainCounts: domainCounts
        )

        return TrafficListSnapshot(
            flows: filteredFlows,
            summary: summary,
            deviceCounts: DeviceFlowCounts(counts: deviceCountsMap),
            markCounts: markCountsMap,
            pinnedFlows: pinnedFlows,
            savedFlows: savedFlows
        )
    }
}

/// Coordinates derivation and caching of `TrafficListSnapshot`.
///
/// Avoids blocking the main thread when derivation takes > ~8 ms by offloading
/// computation to a detached task. Each request carries a generation token so stale
/// asynchronous results are discarded if inputs change while a derivation is in flight.
@MainActor
public final class TrafficListCoordinator: ObservableObject {
    @Published public private(set) var snapshot: TrafficListSnapshot

    public struct DerivationKey: Equatable {
        public let revision: Int
        public let filter: FlowFilter
        public let navigation: SidebarNavigation
        public let pinned: [SidebarEntity]
        public let saved: [SidebarEntity]
        public let deviceSerials: [String]

        public init(
            revision: Int,
            filter: FlowFilter,
            navigation: SidebarNavigation,
            pinned: [SidebarEntity],
            saved: [SidebarEntity],
            deviceSerials: [String]
        ) {
            self.revision = revision
            self.filter = filter
            self.navigation = navigation
            self.pinned = pinned
            self.saved = saved
            self.deviceSerials = deviceSerials
        }
    }

    public var threshold: TimeInterval
    public private(set) var lastKey: DerivationKey?
    public private(set) var generation: Int = 0
    public private(set) var lastDerivationDuration: TimeInterval = 0

    public init(
        initialSnapshot: TrafficListSnapshot = .empty,
        threshold: TimeInterval = 0.008
    ) {
        self.snapshot = initialSnapshot
        self.threshold = threshold
    }

    /// Update the cached snapshot if any input key changed.
    public func updateIfNeeded(
        flows: [Flow],
        revision: Int,
        filter: FlowFilter,
        navigation: SidebarNavigation,
        pinned: [SidebarEntity],
        saved: [SidebarEntity],
        deviceSerials: [String]
    ) {
        let key = DerivationKey(
            revision: revision,
            filter: filter,
            navigation: navigation,
            pinned: pinned,
            saved: saved,
            deviceSerials: deviceSerials
        )
        guard key != lastKey else { return }
        lastKey = key

        generation &+= 1
        let currentGeneration = generation

        // If the last derivation exceeded the budget or flow count is large, compute detached
        let shouldComputeDetached = lastDerivationDuration > threshold || flows.count > 1500

        if shouldComputeDetached {
            Task.detached(priority: .userInitiated) {
                let start = DispatchTime.now()
                let computed = CaptureMetrics.shared.interval(CaptureSignposts.listDerive) {
                    CaptureMetrics.shared.recordListDerivation()
                    return TrafficListSnapshot.compute(
                        flows: flows,
                        filter: filter,
                        navigation: navigation,
                        pinned: pinned,
                        saved: saved,
                        deviceSerials: deviceSerials
                    )
                }
                let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0

                await MainActor.run {
                    guard self.generation == currentGeneration else {
                        // Stale result discarded because a newer generation started
                        return
                    }
                    self.lastDerivationDuration = elapsed
                    self.snapshot = computed
                }
            }
        } else {
            let start = DispatchTime.now()
            let computed = CaptureMetrics.shared.interval(CaptureSignposts.listDerive) {
                CaptureMetrics.shared.recordListDerivation()
                return TrafficListSnapshot.compute(
                    flows: flows,
                    filter: filter,
                    navigation: navigation,
                    pinned: pinned,
                    saved: saved,
                    deviceSerials: deviceSerials
                )
            }
            let elapsed = Double(DispatchTime.now().uptimeNanoseconds - start.uptimeNanoseconds) / 1_000_000_000.0
            self.lastDerivationDuration = elapsed
            self.snapshot = computed
        }
    }
}
