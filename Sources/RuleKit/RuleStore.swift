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
    /// The scenario the user last turned on. It survives a manual rule toggle so the list
    /// can report a modified scenario instead of losing the fact that one is running.
    @Published public var activeMapLocalScenarioID: UUID?

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
        // The saved identifier is what keeps a modified scenario visible across a launch.
        // Files written before it existed fall back to an exact switchboard match.
        if let saved = state.activeMapLocalScenarioID,
           mapLocalScenarios.contains(where: { $0.id == saved }) {
            activeMapLocalScenarioID = saved
        } else {
            activeMapLocalScenarioID = mapLocalScenarios.first { scenario in
                !scenario.ruleIDs.isEmpty && MapLocalScenarioRunner.isActive(scenario, in: mapLocalRules)
            }?.id
        }
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
            mapLocalScenarios: mapLocalScenarios,
            activeMapLocalScenarioID: activeMapLocalScenarioID
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
        var rule = rule
        // While a scenario runs, every rule outside it is off. A new rule joins the
        // switchboard off and is turned on only when it is added to the active scenario.
        if activeMapLocalScenarioID != nil {
            rule.isEnabled = false
        }
        mapLocalRules.append(rule)
    }

    public func updateMapLocalRule(_ rule: MapLocalRule) {
        guard let index = mapLocalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mapLocalRules[index] = rule
    }

    public func removeMapLocalRules(ids: Set<UUID>) {
        mapLocalRules.removeAll { ids.contains($0.id) }
        clearActiveScenarioIfEmpty()
    }

    /// Drop every Map Local rule at once; the switches and SSL policy survive.
    public func clearMapLocalRules() {
        mapLocalRules.removeAll()
        activeMapLocalScenarioID = nil
    }

    // MARK: - Scenarios

    /// Turn on exactly this scenario's rules and turn every other rule off.
    /// Returns the number of existing rules it enabled.
    @discardableResult
    public func activateMapLocalScenario(id: UUID) -> Int {
        guard let scenario = mapLocalScenarios.first(where: { $0.id == id }) else { return 0 }
        let enabled = MapLocalScenarioRunner.activate(scenario, in: &mapLocalRules)
        activeMapLocalScenarioID = enabled > 0 ? id : nil
        return enabled
    }

    public func isMapLocalScenarioActive(_ scenario: MapLocalScenario) -> Bool {
        MapLocalScenarioRunner.isActive(scenario, in: mapLocalRules)
    }

    /// Turn every Map Local rule off and leave the active scenario.
    /// Under exclusive activation this is the one sensible deactivation result: no rule
    /// from the old scenario survives, and no other rule is switched on.
    @discardableResult
    public func turnOffMapLocalRules() -> Int {
        var disabled = 0
        for index in mapLocalRules.indices where mapLocalRules[index].isEnabled {
            mapLocalRules[index].isEnabled = false
            disabled += 1
        }
        activeMapLocalScenarioID = nil
        return disabled
    }

    /// Rename a scenario in place, keeping its identifier and memberships.
    /// Returns false for a blank name or one another scenario already uses.
    @discardableResult
    public func renameMapLocalScenario(id: UUID, to name: String) -> Bool {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, let index = mapLocalScenarios.firstIndex(where: { $0.id == id }) else {
            return false
        }
        let collides = mapLocalScenarios.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
        guard !collides else { return false }
        mapLocalScenarios[index].name = trimmed
        return true
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
        clearActiveScenarioIfEmpty()
    }

    public func removeMapLocalScenario(id: UUID) {
        mapLocalScenarios.removeAll { $0.id == id }
        if activeMapLocalScenarioID == id {
            activeMapLocalScenarioID = nil
        }
    }

    /// Replace one rule's scenario membership to exactly `ids`.
    ///
    /// Used by the rule editor: the checkboxes are the whole truth for this rule, so a
    /// scenario not checked drops the rule and a checked one gains it. A scenario keeps
    /// only one rule per endpoint, so joining one that already answers the same endpoint
    /// removes the older member. The removals are returned so the UI can warn beforehand
    /// and offer an undo afterwards instead of changing another rule silently.
    @discardableResult
    public func setMapLocalScenarios(_ ids: Set<UUID>, forRule ruleID: UUID) -> [MapLocalScenarioSwap] {
        guard let rule = mapLocalRules.first(where: { $0.id == ruleID }) else { return [] }
        var swaps: [MapLocalScenarioSwap] = []

        for index in mapLocalScenarios.indices where ids.contains(mapLocalScenarios[index].id) {
            let scenario = mapLocalScenarios[index]
            let replacedIDs = scenario.ruleIDs.filter { memberID in
                memberID != ruleID
                && mapLocalRules.first(where: { $0.id == memberID })?.endpoint == rule.endpoint
            }
            for replacedID in replacedIDs {
                mapLocalScenarios[index].ruleIDs.removeAll { $0 == replacedID }
                if let replaced = mapLocalRules.first(where: { $0.id == replacedID }) {
                    swaps.append(MapLocalScenarioSwap(
                        scenarioID: scenario.id,
                        scenarioName: scenario.displayName,
                        addedRuleID: ruleID,
                        replacedRuleID: replacedID,
                        replacedRuleName: replaced.displayName
                    ))
                }
            }
            if !mapLocalScenarios[index].ruleIDs.contains(ruleID) {
                mapLocalScenarios[index].ruleIDs.append(ruleID)
            }
            if !replacedIDs.isEmpty, activeMapLocalScenarioID == scenario.id {
                for replacedID in replacedIDs {
                    setMapLocalRule(id: replacedID, enabled: false)
                }
                setMapLocalRule(id: ruleID, enabled: true)
            }
        }

        for index in mapLocalScenarios.indices where !ids.contains(mapLocalScenarios[index].id) {
            mapLocalScenarios[index].ruleIDs.removeAll { $0 == ruleID }
        }

        clearActiveScenarioIfEmpty()
        return swaps
    }

    /// Put a replaced rule back where a swap took it from and restore the switches the
    /// active scenario implies. Later edits are left alone; this only reverses this swap.
    public func undoMapLocalScenarioSwap(_ swap: MapLocalScenarioSwap) {
        guard let index = mapLocalScenarios.firstIndex(where: { $0.id == swap.scenarioID }) else { return }
        mapLocalScenarios[index].ruleIDs.removeAll { $0 == swap.addedRuleID }
        if !mapLocalScenarios[index].ruleIDs.contains(swap.replacedRuleID) {
            mapLocalScenarios[index].ruleIDs.append(swap.replacedRuleID)
        }
        if activeMapLocalScenarioID == swap.scenarioID {
            setMapLocalRule(id: swap.addedRuleID, enabled: false)
            setMapLocalRule(id: swap.replacedRuleID, enabled: true)
        }
        clearActiveScenarioIfEmpty()
    }

    /// A scenario with no surviving rules cannot be a meaningful active setting.
    private func clearActiveScenarioIfEmpty() {
        guard let id = activeMapLocalScenarioID else { return }
        guard let scenario = mapLocalScenarios.first(where: { $0.id == id }) else {
            activeMapLocalScenarioID = nil
            return
        }
        let existing = Set(mapLocalRules.map(\.id))
        if !scenario.ruleIDs.contains(where: existing.contains) {
            activeMapLocalScenarioID = nil
        }
    }

    /// Put a rule in the scenario with this name, adding the scenario when it is new.
    /// A same-name scenario gains the rule rather than being replaced, so typing an
    /// existing name in the editor extends it instead of overwriting its rule set.
    @discardableResult
    public func addRuleToScenario(_ ruleID: UUID, named name: String) -> MapLocalScenario? {
        let name = name.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return nil }
        if let index = mapLocalScenarios.firstIndex(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
            if !mapLocalScenarios[index].ruleIDs.contains(ruleID) {
                mapLocalScenarios[index].ruleIDs.append(ruleID)
            }
            return mapLocalScenarios[index]
        }
        let scenario = MapLocalScenario(name: name, ruleIDs: [ruleID])
        mapLocalScenarios.append(scenario)
        return scenario
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
