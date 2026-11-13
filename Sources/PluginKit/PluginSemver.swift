import Foundation

/// Minimal semantic version parsing for the plugin SDK contract.
///
/// Accepts `major.minor.patch` (later components optional), ignoring any prerelease
/// or build suffix — a plugin that declares `1.2.0-beta.1` is treated as `1.2.0`.
public struct PluginSemver: Equatable, Comparable, Sendable {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        // Drop a prerelease/build suffix; only the numeric core is compared.
        let core = trimmed.split(whereSeparator: { $0 == "-" || $0 == "+" }).first.map(String.init) ?? trimmed
        let parts = core.split(separator: ".")
        guard (1...3).contains(parts.count),
              parts.allSatisfy({ !$0.isEmpty && $0.allSatisfy(\.isNumber) }) else { return nil }
        let numbers = parts.compactMap { Int($0) }
        guard numbers.count == parts.count else { return nil }
        let padded = numbers + Array(repeating: 0, count: 3 - numbers.count)
        self.init(major: padded[0], minor: padded[1], patch: padded[2])
    }

    public static func < (lhs: PluginSemver, rhs: PluginSemver) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }
}

/// A semver range a plugin manifest may declare in its `sdkVersion` field.
///
/// Supported forms (space-separated forms are ANDed together):
///
/// * `*` — any version
/// * `1.2.3` — exact version
/// * `^1.2.3` — compatible up to the next breaking release
/// * `~1.2.3` — compatible up to the next minor release
/// * `>=1.2.3`, `>1.2.3`, `<=1.2.3`, `<1.2.3` — comparisons
/// * `1.0.0 - 2.0.0` — inclusive span
public struct PluginSemverRange: Equatable, Sendable {
    private enum Constraint: Equatable, Sendable {
        case any
        case exact(PluginSemver)
        case atLeast(PluginSemver)
        case atMost(PluginSemver)
        case greaterThan(PluginSemver)
        case lessThan(PluginSemver)

        func contains(_ version: PluginSemver) -> Bool {
            switch self {
            case .any: return true
            case .exact(let bound): return version == bound
            case .atLeast(let bound): return version >= bound
            case .atMost(let bound): return version <= bound
            case .greaterThan(let bound): return version > bound
            case .lessThan(let bound): return version < bound
            }
        }
    }

    private let constraints: [Constraint]

    private init(constraints: [Constraint]) {
        self.constraints = constraints
    }

    public init?(parsing text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }

        var constraints: [Constraint] = []
        // `A - B` is the only form where a space joins two versions.
        if let lowerEnd = trimmed.range(of: " - "),
           let lower = PluginSemver(parsing: String(trimmed[trimmed.startIndex..<lowerEnd.lowerBound])),
           let upper = PluginSemver(parsing: String(trimmed[lowerEnd.upperBound...])) {
            constraints = [.atLeast(lower), .atMost(upper)]
        } else {
            for token in trimmed.split(separator: " ") {
                guard let parsed = Self.parseConstraint(String(token)) else { return nil }
                constraints.append(contentsOf: parsed)
            }
        }
        guard !constraints.isEmpty else { return nil }
        self.init(constraints: constraints)
    }

    private static func parseConstraint(_ token: String) -> [Constraint]? {
        if token == "*" || token == "x" { return [.any] }
        // Longest markers first, so ">=" wins over ">".
        let markers = ["^", "~", ">=", "<=", ">", "<", "="]
        let matched = markers.first { token.hasPrefix($0) }
        let versionText = matched.map { String(token.dropFirst($0.count)) } ?? token
        guard let version = PluginSemver(parsing: versionText) else { return nil }
        switch matched {
        case "^":
            // Compatible within the current breaking boundary: at or above the declared
            // version, below the next major — except below 1.0, where minor/patch
            // bumps still count as breaking.
            let upper: PluginSemver
            if version.major > 0 {
                upper = PluginSemver(major: version.major + 1)
            } else if version.minor > 0 {
                upper = PluginSemver(major: 0, minor: version.minor + 1)
            } else {
                upper = PluginSemver(major: 0, minor: 0, patch: version.patch + 1)
            }
            return [.atLeast(version), .lessThan(upper)]
        case "~":
            return [.atLeast(version), .lessThan(PluginSemver(major: version.major, minor: version.minor + 1))]
        case ">=": return [.atLeast(version)]
        case "<=": return [.atMost(version)]
        case ">": return [.greaterThan(version)]
        case "<": return [.lessThan(version)]
        case "=", nil: return [.exact(version)]
        default: return nil
        }
    }

    public func contains(_ version: PluginSemver) -> Bool {
        constraints.allSatisfy { $0.contains(version) }
    }

    /// True when the host SDK version satisfies this range.
    public func isSatisfiedByHostSDK() -> Bool {
        contains(PluginSemver(parsing: PluginSDK.version) ?? PluginSemver(major: 0, minor: 0, patch: 0))
    }
}

/// The SDK surface ProxyMaxx advertises to plugins. Bumping this is a compatibility
/// decision: manifests whose `sdkVersion` range excludes it fail to load.
public enum PluginSDK {
    public static let version = "1.0.0"
}
