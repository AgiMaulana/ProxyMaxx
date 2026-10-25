import Foundation

public struct MapLocalBundle: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var ruleIDs: [UUID]

    public init(id: UUID = UUID(), name: String, ruleIDs: [UUID]) {
        self.id = id
        self.name = name
        self.ruleIDs = ruleIDs
    }

    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? id.uuidString : trimmed
    }
}

public struct MapLocalBundleManifest: Codable, Equatable, Sendable {
    public var formatVersion: Int
    public var id: UUID
    public var name: String
    public var overrides: [MapLocalRule]

    public init(formatVersion: Int = 1, id: UUID = UUID(), name: String, overrides: [MapLocalRule]) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.overrides = overrides
    }
}

public enum MapLocalBundleError: LocalizedError {
    case invalidArchive(String)
    case unsupportedVersion(Int)
    case invalidRule(String)
    case resourceLimit(String)
    case collision(String)
    case bundleNotFound(String)
    case ambiguousSelector(String)

    public var errorDescription: String? {
        switch self {
        case .invalidArchive(let reason): return "Invalid bundle ZIP: \(reason)"
        case .unsupportedVersion(let version): return "Bundle format version \(version) is unsupported; expected version 1."
        case .invalidRule(let reason): return "Invalid bundle rule: \(reason)"
        case .resourceLimit(let reason): return "Bundle exceeds the resource limit: \(reason)"
        case .collision(let reason): return "Bundle identity collision: \(reason)"
        case .bundleNotFound(let selector): return "No imported bundle matches '\(selector)'."
        case .ambiguousSelector(let selector): return "More than one bundle matches '\(selector)'; use its UUID."
        }
    }
}
