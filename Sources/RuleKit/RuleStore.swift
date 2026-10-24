import Foundation
import Combine
import Branding

/// Observable container for the user's debugging rules.
///
/// Phase 1 exposes the SSL Proxying list; the remaining tool rule sets are added alongside
/// their tools in Phase 2.
@MainActor
public final class RuleStore: ObservableObject {
    @Published public var sslProxyingPolicy: SSLProxyingPolicy = .decryptAll
    @Published public var isSSLProxyingEnabled: Bool = true

    /// Map Local rules, in the order they are evaluated.
    @Published public var mapLocalRules: [MapLocalRule] = []
    @Published public var isMapLocalEnabled: Bool = true
    /// Named sets of Map Local rules, activated as a group.
    @Published public var mapLocalScenarios: [MapLocalScenario] = []

    /// Where the rules are saved on disk; `nil` keeps the store in memory only, which is
    /// what unit tests want so they never read each other's leftovers.
    private let persistenceURL: URL?
    private var cancellables = Set<AnyCancellable>()

    /// The on-disk location the app uses, under `Application Support/ProxyMaxx`.
    public static var defaultPersistenceURL: URL {
        Brand.supportDirectory.appendingPathComponent("rules.json")
    }

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let persistenceURL {
            loadSavedState(from: persistenceURL)
        }
        objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// Read back a previous run's rules. A missing or corrupt file leaves the defaults.
    private func loadSavedState(from url: URL) {
        let state = RuleFile.load(from: url)
        isSSLProxyingEnabled = state.isSSLProxyingEnabled
        sslProxyingPolicy = state.sslProxyingPolicy
        isMapLocalEnabled = state.isMapLocalEnabled
        mapLocalRules = state.mapLocalRules
        mapLocalScenarios = state.mapLocalScenarios
    }

    private func save() {
        guard let persistenceURL else { return }
        // Best-effort: losing one save on a full disk beats throwing inside a Combine
        // sink, and the atomic write keeps a crash from truncating the file.
        try? currentRuleFile().write(to: persistenceURL)
    }

    /// A snapshot of everything the store holds, in the on-disk `RuleFile` shape.
    public func currentRuleFile() -> RuleFile {
        RuleFile(
            isSSLProxyingEnabled: isSSLProxyingEnabled,
            sslProxyingPolicy: sslProxyingPolicy,
            isMapLocalEnabled: isMapLocalEnabled,
            mapLocalRules: mapLocalRules,
            mapLocalScenarios: mapLocalScenarios
        )
    }

    /// Write the current state now, instead of waiting for the debounced save.
    /// The app calls this on quit so the last change before ⌘Q is not dropped.
    public func flushRulesToDisk() {
        save()
    }

    public var includeList: [String] { sslProxyingPolicy.include }
    public var excludeList: [String] { sslProxyingPolicy.exclude }

    public func addInclude(_ pattern: String) {
        let pattern = Self.normalizePattern(pattern)
        guard !pattern.isEmpty, !sslProxyingPolicy.include.contains(pattern) else { return }
        sslProxyingPolicy.include.append(pattern)
    }

    public func addExclude(_ pattern: String) {
        let pattern = Self.normalizePattern(pattern)
        guard !pattern.isEmpty, !sslProxyingPolicy.exclude.contains(pattern) else { return }
        sslProxyingPolicy.exclude.append(pattern)
    }

    public func removeInclude(_ pattern: String) {
        sslProxyingPolicy.include.removeAll { $0 == pattern }
    }

    public func removeExclude(_ pattern: String) {
        sslProxyingPolicy.exclude.removeAll { $0 == pattern }
    }

    /// The policy the proxy should apply right now.
    public var effectivePolicy: SSLProxyingPolicy {
        isSSLProxyingEnabled ? sslProxyingPolicy : SSLProxyingPolicy(include: [], exclude: [])
    }

    // MARK: - Map Local

    /// The rules the proxy should apply right now, in evaluation order.
    public var effectiveMapLocalRules: [MapLocalRule] {
        isMapLocalEnabled ? mapLocalRules : []
    }

    public func addMapLocalRule(_ rule: MapLocalRule) {
        mapLocalRules.append(rule)
    }

    public func updateMapLocalRule(_ rule: MapLocalRule) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mapLocalRules[index] = rule
    }

    public func removeMapLocalRules(ids: Set<UUID>) {
        mapLocalRules.removeAll { ids.contains($0.id) }
    }

    /// Drop every Map Local rule at once; the switches and SSL policy survive.
    public func clearMapLocalRules() {
        mapLocalRules.removeAll()
    }

    // MARK: - Scenarios

    /// Turn on exactly this scenario's rules and turn every other rule off.
    /// Returns the number of existing rules it enabled.
    @discardableResult
    public func activateMapLocalScenario(id: UUID) -> Int {
        guard let scenario = mapLocalScenarios.first(where: { $0.id == id }) else { return 0 }
        return MapLocalScenarioRunner.activate(scenario, in: &mapLocalRules)
    }

    public func isMapLocalScenarioActive(_ scenario: MapLocalScenario) -> Bool {
        MapLocalScenarioRunner.isActive(scenario, in: mapLocalRules)
    }

    /// Add a scenario, replacing any existing one with the same name so the CLI's
    /// `create` is idempotent. The replacement keeps the original identifier.
    public func saveMapLocalScenario(_ scenario: MapLocalScenario) {
        let name = scenario.name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        if let index = mapLocalScenarios.firstIndex(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame || $0.id == scenario.id
        }) {
            var updated = scenario
            updated.name = name
            updated.id = mapLocalScenarios[index].id
            mapLocalScenarios[index] = updated
        } else {
            var added = scenario
            added.name = name
            mapLocalScenarios.append(added)
        }
    }

    public func removeMapLocalScenario(id: UUID) {
        mapLocalScenarios.removeAll { $0.id == id }
    }

    public func duplicateMapLocalRule(id: UUID) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        var copy = mapLocalRules[index]
        copy.id = UUID()
        copy.name = copy.name.isEmpty ? "" : "\(copy.name) copy"
        mapLocalRules.insert(copy, at: index + 1)
    }

    public func setMapLocalRule(id: UUID, enabled: Bool) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        mapLocalRules[index].isEnabled = enabled
    }

    /// Reorder the list, since rule order decides which rule wins.
    public func moveMapLocalRules(from offsets: IndexSet, to destination: Int) {
        let moved = offsets.sorted().map { mapLocalRules[$0] }
        var remaining = mapLocalRules
        for index in offsets.sorted(by: >) { remaining.remove(at: index) }
        let insertAt = max(0, min(destination - offsets.filter { $0 < destination }.count, remaining.count))
        remaining.insert(contentsOf: moved, at: insertAt)
        mapLocalRules = remaining
    }

    public func moveMapLocalRule(id: UUID, by offset: Int) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard mapLocalRules.indices.contains(target) else { return }
        mapLocalRules.swapAt(index, target)
    }

    static func normalizePattern(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
