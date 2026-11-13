import Foundation
import Combine
import Branding

/// The Local Override operations a plugin caller can perform. Each maps to one
/// permission in the Plugin Store's registry (`local-map.read/.create/.update/.delete`,
/// docs/plugin-store-phase1.md §10); the mapping lives here so the boundary and the
/// permission list cannot drift apart.
public enum LocalMapOperation: String, Sendable {
    case read
    case create
    case update
    case delete
}

/// Thrown when a plugin caller arrives and no authorization gate is installed. A
/// missing gate must deny rather than silently allow — plugin traffic never flows
/// with the enforcement unplugged.
public struct LocalMapEnforcementUnavailableError: Error, CustomStringConvertible {
    public init() {}
    public var description: String {
        "Plugin authorization is not configured, so the Local Override operation was denied."
    }
}


/// Observable container for the user's debugging rules.
@MainActor
public final class RuleStore: ObservableObject {
    @Published public var sslProxyingPolicy: SSLProxyingPolicy = .decryptAll
    @Published public var isSSLProxyingEnabled: Bool = true

    /// Map Local rules, in the order they are evaluated.
    @Published public var mapLocalRules: [MapLocalRule] = []
    @Published public var isMapLocalEnabled: Bool = true
    @Published public var mapLocalBundles: [MapLocalBundle] = []
    public let bundleStorageDirectory: URL

    /// Where the rules are saved on disk; `nil` keeps the store in memory only, which is
    /// what unit tests want so they never read each other's leftovers.
    private let persistenceURL: URL?
    private var cancellables = Set<AnyCancellable>()
    /// The bytes this store last read from, or wrote to, `persistenceURL`. Comparing the
    /// file against this is how the store notices an outside writer.
    private var lastPersistedBytes: Data?
    /// True when a change made *here* has not reached disk yet. Only such a change is
    /// allowed to replace a file that changed underneath us.
    private var hasPendingLocalChanges = false
    /// Set while adopting an external revision, so its `@Published` writes are not
    /// mistaken for a local edit.
    private var isReloadingFromDisk = false

    /// The on-disk location the app uses, under `Application Support/ProxyMaxx`.
    public static var defaultPersistenceURL: URL {
        Brand.supportDirectory.appendingPathComponent("rules.json")
    }

    /// Plugin permission enforcement for the Local Override boundary
    /// (docs/plugin-store-phase1.md §10). The app installs this hook at startup; it
    /// receives the caller's plugin id and the operation about to execute, and throws
    /// to reject. Internal callers — this app's UI and the human-operated CLI — pass
    /// no plugin id at all and are never gated; only plugin-originated traffic is.
    ///
    /// All rule mutations funnel through the methods below, so no in-app route can
    /// bypass the gate. `proxymaxx-cli` writes `rules.json` directly when the app is
    /// not serving; it is a human tool with no plugin identity and stays outside the
    /// plugin permission model.
    public var localMapAuthorizationGate: ((_ callerPluginID: String, _ operation: LocalMapOperation) throws -> Void)?

    /// Plugin callers are denied when no gate is installed: fail closed.
    private func authorizePlugin(callerPluginID: String?, _ operation: LocalMapOperation) throws {
        guard let callerPluginID else { return }
        guard let localMapAuthorizationGate else { throw LocalMapEnforcementUnavailableError() }
        try localMapAuthorizationGate(callerPluginID, operation)
    }

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        bundleStorageDirectory = (persistenceURL?.deletingLastPathComponent()
            ?? FileManager.default.temporaryDirectory.appendingPathComponent("ProxyMaxx-rules-\(UUID().uuidString)"))
            .appendingPathComponent("local-override-bundles", isDirectory: true)
        if let persistenceURL {
            loadSavedState(from: persistenceURL)
        }
        // Mark the store dirty the moment a value changes, before the debounce: the save
        // that eventually runs has to know whether this store or an outside writer is the
        // newer revision.
        objectWillChange
            .sink { [weak self] _ in
                guard let self, !self.isReloadingFromDisk else { return }
                self.hasPendingLocalChanges = true
            }
            .store(in: &cancellables)
        objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// Read back a previous run's rules. A missing or corrupt file leaves the defaults.
    private func loadSavedState(from url: URL) {
        isReloadingFromDisk = true
        defer {
            isReloadingFromDisk = false
            hasPendingLocalChanges = false
        }
        guard let data = try? Data(contentsOf: url) else {
            lastPersistedBytes = nil
            return
        }
        lastPersistedBytes = data
        guard let state = try? JSONDecoder().decode(RuleFile.self, from: data) else { return }
        isSSLProxyingEnabled = state.isSSLProxyingEnabled
        sslProxyingPolicy = state.sslProxyingPolicy
        isMapLocalEnabled = state.isMapLocalEnabled
        mapLocalRules = state.mapLocalRules
        mapLocalBundles = state.mapLocalBundles
    }

    private func save() {
        guard let persistenceURL else { return }

        // `proxymaxx-cli` writes this same file directly whenever the app is not hosting
        // the engine, so the in-memory copy here can be stale. Overwriting it with that
        // copy is what made a CLI mutation report `ok: true` and then vanish on quit.
        // Adopt the newer revision instead; only a change made in this app since it last
        // read or wrote the file may replace what is there.
        if !hasPendingLocalChanges,
           let onDisk = try? Data(contentsOf: persistenceURL),
           onDisk != lastPersistedBytes {
            loadSavedState(from: persistenceURL)
            return
        }

        // Best-effort: losing one save on a full disk beats throwing inside a Combine
        // sink, and the atomic write keeps a crash from truncating the file.
        guard let data = try? internalRuleFile().encoded() else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        guard (try? data.write(to: persistenceURL, options: .atomic)) != nil else { return }
        lastPersistedBytes = data
        hasPendingLocalChanges = false
    }

    /// A snapshot of everything the store holds, in the on-disk `RuleFile` shape.
    /// Plugin callers are gated on `local-map.read`; internal callers pass nothing.
    public func currentRuleFile(callerPluginID: String? = nil) throws -> RuleFile {
        try authorizePlugin(callerPluginID: callerPluginID, .read)
        return internalRuleFile()
    }

    /// Ungated snapshot for the store's own persistence and mutation plumbing; the
    /// public entry points gate on the caller before touching state.
    private func internalRuleFile() -> RuleFile {
        RuleFile(
            isSSLProxyingEnabled: isSSLProxyingEnabled,
            sslProxyingPolicy: sslProxyingPolicy,
            isMapLocalEnabled: isMapLocalEnabled,
            mapLocalRules: mapLocalRules,
            mapLocalBundles: mapLocalBundles
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

    public func addMapLocalRule(_ rule: MapLocalRule, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .create)
        mapLocalRules.append(rule)
    }

    public func updateMapLocalRule(_ rule: MapLocalRule, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        guard let index = mapLocalRules.firstIndex(where: { $0.id == rule.id }) else { return }
        mapLocalRules[index] = rule
    }

    public func removeMapLocalRules(ids: Set<UUID>, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .delete)
        mapLocalRules.removeAll { ids.contains($0.id) }
        for index in mapLocalBundles.indices {
            mapLocalBundles[index].ruleIDs.removeAll { ids.contains($0) }
        }
    }

    /// Drop every Map Local rule at once; the switches and SSL policy survive.
    public func clearMapLocalRules(callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .delete)
        mapLocalRules.removeAll()
        for index in mapLocalBundles.indices { mapLocalBundles[index].ruleIDs.removeAll() }
    }

    // MARK: - Bundles

    @discardableResult
    public func importMapLocalBundle(from url: URL, activate: Bool = false, callerPluginID: String? = nil) throws -> MapLocalBundle {
        try authorizePlugin(callerPluginID: callerPluginID, .create)
        var file = internalRuleFile()
        let bundle = try MapLocalBundleArchive.importBundle(
            from: url, into: &file, storageDirectory: bundleStorageDirectory,
            activate: activate, persistTo: persistenceURL
        )
        applyBundleState(file)
        return bundle
    }

    public func exportMapLocalBundle(id: UUID, to url: URL, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .read)
        let file = internalRuleFile()
        let bundle = try MapLocalBundleState.resolve(id.uuidString, in: file)
        try MapLocalBundleArchive.exportBundle(
            rules: MapLocalBundleState.rules(in: bundle, from: file),
            name: bundle.name, id: bundle.id, to: url
        )
    }

    public func exportMapLocalRules(ids: Set<UUID>? = nil, name: String, to url: URL, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .read)
        let selected = mapLocalRules.filter { ids?.contains($0.id) ?? true }
        try MapLocalBundleArchive.exportBundle(rules: selected, name: name, to: url)
    }

    @discardableResult
    public func activateMapLocalBundle(id: UUID, callerPluginID: String? = nil) throws -> Int {
        try authorizePlugin(callerPluginID: callerPluginID, .create)
        var file = internalRuleFile()
        let count = try MapLocalBundleState.activate(id: id, in: &file)
        try persistBundleState(file)
        return count
    }

    @discardableResult
    public func deactivateMapLocalBundle(id: UUID, callerPluginID: String? = nil) throws -> Int {
        try authorizePlugin(callerPluginID: callerPluginID, .delete)
        var file = internalRuleFile()
        let count = try MapLocalBundleState.deactivate(id: id, in: &file)
        try persistBundleState(file)
        return count
    }

    public func removeMapLocalBundle(id: UUID, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .delete)
        var file = internalRuleFile()
        try MapLocalBundleState.remove(
            id: id, from: &file, storageDirectory: bundleStorageDirectory, persistTo: persistenceURL
        )
        applyBundleState(file)
    }

    public func isMapLocalBundleActive(_ bundle: MapLocalBundle) -> Bool {
        isMapLocalEnabled && MapLocalBundleState.isActive(bundle, in: mapLocalRules)
    }

    private func persistBundleState(_ file: RuleFile) throws {
        if let persistenceURL { try file.write(to: persistenceURL) }
        applyBundleState(file)
    }

    private func applyBundleState(_ file: RuleFile) {
        mapLocalRules = file.mapLocalRules
        mapLocalBundles = file.mapLocalBundles
        isMapLocalEnabled = file.isMapLocalEnabled
    }

    @discardableResult
    public func turnOffMapLocalRules(callerPluginID: String? = nil) throws -> Int {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        var disabled = 0
        for index in mapLocalRules.indices where mapLocalRules[index].isEnabled {
            mapLocalRules[index].isEnabled = false
            disabled += 1
        }
        return disabled
    }


    public func duplicateMapLocalRule(id: UUID, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        var copy = mapLocalRules[index]
        copy.id = UUID()
        copy.name = copy.name.isEmpty ? "" : "\(copy.name) copy"
        mapLocalRules.insert(copy, at: index + 1)
        if let owner = mapLocalBundles.firstIndex(where: { $0.ruleIDs.contains(id) }) {
            mapLocalBundles[owner].ruleIDs.append(copy.id)
        }
    }

    public func setMapLocalRule(id: UUID, enabled: Bool, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        mapLocalRules[index].isEnabled = enabled
    }

    /// Reorder the list, since rule order decides which rule wins.
    public func moveMapLocalRules(from offsets: IndexSet, to destination: Int, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        let moved = offsets.sorted().map { mapLocalRules[$0] }
        var remaining = mapLocalRules
        for index in offsets.sorted(by: >) { remaining.remove(at: index) }
        let insertAt = max(0, min(destination - offsets.filter { $0 < destination }.count, remaining.count))
        remaining.insert(contentsOf: moved, at: insertAt)
        mapLocalRules = remaining
    }

    public func moveMapLocalRule(id: UUID, by offset: Int, callerPluginID: String? = nil) throws {
        try authorizePlugin(callerPluginID: callerPluginID, .update)
        guard let index = mapLocalRules.firstIndex(where: { $0.id == id }) else { return }
        let target = index + offset
        guard mapLocalRules.indices.contains(target) else { return }
        mapLocalRules.swapAt(index, target)
    }

    static func normalizePattern(_ pattern: String) -> String {
        pattern.trimmingCharacters(in: .whitespaces).lowercased()
    }
}
