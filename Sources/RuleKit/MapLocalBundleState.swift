import Foundation

public enum MapLocalBundleState {
    public static func resolve(_ selector: String, in file: RuleFile) throws -> MapLocalBundle {
        let selector = selector.trimmingCharacters(in: .whitespacesAndNewlines)
        if let id = UUID(uuidString: selector) {
            return try bundle(id: id, in: file)
        }
        let normalized = normalizedName(selector)
        let exact = file.mapLocalBundles.filter { normalizedName($0.name) == normalized }
        if exact.count == 1 { return exact[0] }
        if exact.count > 1 { throw MapLocalBundleError.ambiguousSelector(selector) }
        let matches = file.mapLocalBundles.filter { slug($0.name) == normalized }
        guard !matches.isEmpty else { throw MapLocalBundleError.bundleNotFound(selector) }
        guard matches.count == 1 else { throw MapLocalBundleError.ambiguousSelector(selector) }
        return matches[0]
    }

    @discardableResult
    public static func activate(id: UUID, in file: inout RuleFile) throws -> Int {
        let selected = try bundle(id: id, in: file)
        try validateOwnership(selected, in: file)
        let wanted = Set(selected.ruleIDs)
        guard file.mapLocalRules.contains(where: { wanted.contains($0.id) }) else {
            throw MapLocalBundleError.invalidRule("The bundle has no remaining rules to activate.")
        }
        var count = 0
        for index in file.mapLocalRules.indices {
            let member = wanted.contains(file.mapLocalRules[index].id)
            file.mapLocalRules[index].isEnabled = member
            if member { count += 1 }
        }
        file.isMapLocalEnabled = true
        return count
    }

    @discardableResult
    public static func deactivate(id: UUID, in file: inout RuleFile) throws -> Int {
        let selected = try bundle(id: id, in: file)
        try validateOwnership(selected, in: file)
        let wanted = Set(selected.ruleIDs)
        var count = 0
        for index in file.mapLocalRules.indices where wanted.contains(file.mapLocalRules[index].id) {
            if file.mapLocalRules[index].isEnabled { count += 1 }
            file.mapLocalRules[index].isEnabled = false
        }
        return count
    }

    public static func isActive(_ bundle: MapLocalBundle, in rules: [MapLocalRule]) -> Bool {
        let wanted = Set(bundle.ruleIDs)
        let existing = Set(rules.lazy.filter { wanted.contains($0.id) }.map(\.id))
        return !existing.isEmpty && rules.allSatisfy { $0.isEnabled == existing.contains($0.id) }
    }

    public static func rules(in bundle: MapLocalBundle, from file: RuleFile) -> [MapLocalRule] {
        let wanted = Set(bundle.ruleIDs)
        return file.mapLocalRules.filter { wanted.contains($0.id) }
    }

    public static func remove(id: UUID, from file: inout RuleFile, storageDirectory: URL, persistTo: URL? = nil) throws {
        let selected = try bundle(id: id, in: file)
        try validateOwnership(selected, in: file)
        let owned = Set(selected.ruleIDs)
        var candidate = file
        candidate.mapLocalRules.removeAll { owned.contains($0.id) }
        candidate.mapLocalBundles.removeAll { $0.id == id }
        if let persistTo { try candidate.write(to: persistTo) }
        file = candidate

        // Rule edits can deliberately point an ordinary rule at imported data. Keep the
        // managed directory in that case; removing a bundle must not break unowned rules.
        guard let root = try? MapLocalBundleStorage.root(storageDirectory, create: false) else { return }
        let managed = root.appendingPathComponent(id.uuidString, isDirectory: true)
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: managed.path),
              attributes[.type] as? FileAttributeType == .typeDirectory else { return }
        let managedPath = managed.standardizedFileURL.path
        let referenced = candidate.mapLocalRules.contains {
            let path = MapLocalResponder.expand($0.destination.path).resolvingSymlinksInPath().standardizedFileURL.path
            return path == managedPath || path.hasPrefix(managedPath + "/")
        }
        guard !referenced else { return }
        // Persistence is already committed. Cleanup failure must not report a failed
        // transaction or restore references to data that may have been partly removed.
        try? FileManager.default.removeItem(at: managed)
    }

    static func normalizedName(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespacesAndNewlines).precomposedStringWithCanonicalMapping.lowercased()
    }

    private static func slug(_ name: String) -> String {
        normalizedName(name).components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { !$0.isEmpty }.joined(separator: "-")
    }

    private static func bundle(id: UUID, in file: RuleFile) throws -> MapLocalBundle {
        let matches = file.mapLocalBundles.filter { $0.id == id }
        guard !matches.isEmpty else { throw MapLocalBundleError.bundleNotFound(id.uuidString) }
        guard matches.count == 1 else { throw MapLocalBundleError.ambiguousSelector(id.uuidString) }
        return matches[0]
    }

    private static func validateOwnership(_ bundle: MapLocalBundle, in file: RuleFile) throws {
        let owned = Set(bundle.ruleIDs)
        guard !file.mapLocalBundles.contains(where: { $0.id != bundle.id && $0.ruleIDs.contains(where: owned.contains) }) else {
            throw MapLocalBundleError.collision("A rule is owned by more than one bundle.")
        }
    }
}

struct MapLocalBundleStorage {
    static func root(_ url: URL, create: Bool) throws -> URL {
        guard url.isFileURL else { throw MapLocalBundleError.invalidArchive("Managed storage must be a local directory.") }
        let manager = FileManager.default
        if let attributes = try? manager.attributesOfItem(atPath: url.path) {
            guard attributes[.type] as? FileAttributeType == .typeDirectory else {
                throw MapLocalBundleError.invalidArchive("Managed storage is not a regular directory: \(url.path)")
            }
        } else if create {
            try manager.createDirectory(at: url, withIntermediateDirectories: true)
        } else {
            throw CocoaError(.fileNoSuchFile)
        }
        return url.resolvingSymlinksInPath().standardizedFileURL
    }
}
