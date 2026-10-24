import Foundation
import FlowKit

/// How a Map Local URL pattern is compared against a request.
///
/// The raw values mirror ProxyMaxx's `RegexMatching`, so a rule carried across from
/// either tool keeps its meaning.
public enum URLMatchStyle: String, Codable, Sendable, CaseIterable {
    /// The pattern is a substring of the request URL.
    case contains
    /// Shell-style `*` / `?` wildcards, matched against the whole URL.
    case wildcard
    /// A regular expression matched against the whole URL, not a substring of it.
    case regex
    /// The whole URL, verbatim.
    case exact

    public var displayName: String {
        switch self {
        case .contains: return String(localized: "mapLocal.style.contains", defaultValue: "Contains")
        case .wildcard: return String(localized: "mapLocal.style.wildcard", defaultValue: "Match Wildcard")
        case .regex: return String(localized: "mapLocal.style.regex", defaultValue: "Match Regex")
        case .exact: return String(localized: "mapLocal.style.exact", defaultValue: "Exact")
        }
    }

    public var help: String {
        switch self {
        case .contains: return String(localized: "mapLocal.style.containsHelp", defaultValue: "Any URL that contains this text matches. The most forgiving style.")
        case .wildcard: return String(localized: "mapLocal.style.wildcardHelp", defaultValue: "`*` matches any run of characters and `?` matches one. Use `/*` at the end to cover a path and everything below it.")
        case .regex: return String(localized: "mapLocal.style.regexHelp", defaultValue: "A full-match regular expression. Wrap the tail in `(.*)` to accept the rest of the URL.")
        case .exact: return String(localized: "mapLocal.style.exactHelp", defaultValue: "The request URL must equal this text exactly.")
        }
    }
}

/// The HTTP method a rule applies to. An empty value means any method.
public struct MethodMatch: Hashable, Sendable, Codable {
    /// Matches every method.
    public static let any = MethodMatch()

    private let value: String

    public init(_ value: String = "") {
        self.value = value.trimmingCharacters(in: .whitespaces).uppercased()
    }

    public var isAny: Bool { value.isEmpty }

    /// The name shown in the rule list: `ANY` or the method itself.
    public var displayName: String { isAny ? "ANY" : value }

    public func matches(_ method: String) -> Bool {
        isAny || method.caseInsensitiveCompare(value) == .orderedSame
    }
}

/// Where a matched request is answered from.
public enum MapLocalDestination: Hashable, Sendable, Codable {
    /// A single local file, served as a full HTTP message or as a response body.
    case file(String)
    /// A directory whose contents stand in for the matched URL subtree.
    case directory(String)

    public var path: String {
        switch self {
        case .file(let path), .directory(let path): return path
        }
    }

    public var isFile: Bool {
        if case .file = self { return true }
        return false
    }

    public var displayName: String { isFile ? String(localized: "mapLocal.localFile", defaultValue: "Local File") : String(localized: "mapLocal.localDirectory", defaultValue: "Local Directory") }

    /// The symbol shown beside the rule in the list.
    public var symbolName: String { isFile ? "doc" : "folder" }
}

/// One Map Local rule: a URL pattern, an optional method, and the local content to serve.
///
/// Rules are evaluated in list order and the first match wins, matching ProxyMaxx's
/// "checked against the rules from top to bottom" behaviour.
public struct MapLocalRule: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var method: MethodMatch
    /// The pattern written into the URL field, for example `api.proxymaxx.com/v1/*`.
    public var url: String
    public var matchStyle: URLMatchStyle
    /// When true the path is part of the comparison; otherwise only the host is.
    ///
    /// ProxyMaxx labels this "Include all subpaths of this URL".
    public var includePath: Bool
    public var destination: MapLocalDestination
    /// Seconds to wait before the mapped response is sent.
    public var responseDelay: TimeInterval

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        method: MethodMatch = .any,
        url: String = "",
        matchStyle: URLMatchStyle = .wildcard,
        includePath: Bool = true,
        destination: MapLocalDestination = .file(""),
        responseDelay: TimeInterval = 0
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.method = method
        self.url = url
        self.matchStyle = matchStyle
        self.includePath = includePath
        self.destination = destination
        self.responseDelay = responseDelay
    }

    /// The value the URL column shows. An unnamed rule falls back to its pattern.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? url : trimmed
    }

    /// What the rule answers: its method and URL pattern. Scenarios use this to keep one
    /// rule per endpoint, so two answers for the same requests cannot race.
    public var endpoint: MapLocalEndpoint {
        MapLocalEndpoint(method: method.displayName, pattern: url.trimmingCharacters(in: .whitespaces))
    }
}

/// The method-and-pattern pair that identifies an endpoint in the rule list.
///
/// Match style and destination are not part of the identity: they change how the answer
/// is produced, not which requests the rule claims.
public struct MapLocalEndpoint: Hashable, Sendable {
    public let method: String
    public let pattern: String

    public init(method: String, pattern: String) {
        self.method = method
        self.pattern = pattern
    }

    /// The grouping header, for example `GET consultation/*`.
    public var label: String {
        pattern.isEmpty ? method : "\(method) \(pattern)"
    }

    /// Stable identity for dictionaries and section identifiers.
    public var key: String { "\(method)\u{1F}\(pattern)" }
}

/// Names for rules that were saved with an empty name field.
///
/// The form shows "Untitled Rule" as a placeholder rather than prefilling it, so the list
/// gets a real, unique name when the rule is created.
public enum MapLocalRuleNaming {
    public static func untitled(existingNames: [String]) -> String {
        let base = String(localized: "mapLocal.untitledRule", defaultValue: "Untitled Rule")
        let taken = Set(existingNames.map(normalized))
        guard taken.contains(normalized(base)) else { return base }

        var number = 2
        while taken.contains(normalized(numbered(base, number))) {
            number += 1
        }
        return numbered(base, number)
    }

    private static func numbered(_ base: String, _ number: Int) -> String {
        String(
            format: String(localized: "mapLocal.untitledRuleNumbered", defaultValue: "Untitled Rule %lld"),
            number
        )
    }

    private static func normalized(_ name: String) -> String {
        name.trimmingCharacters(in: .whitespaces).lowercased()
    }
}

/// The delay choices ProxyMaxx offers in the editor.
public enum MapLocalDelay: Double, CaseIterable, Identifiable, Sendable {
    case none = 0
    case oneSecond = 1
    case twoSeconds = 2
    case threeSeconds = 3
    case fiveSeconds = 5
    case tenSeconds = 10
    case thirtySeconds = 30
    case sixtySeconds = 60

    public var id: Double { rawValue }

    public var displayName: String {
        switch self {
        case .none: return String(localized: "mapLocal.delay.none", defaultValue: "No Delay")
        case .oneSecond: return String(localized: "mapLocal.delay.oneSecond", defaultValue: "1 second")
        default: return String(format: String(localized: "mapLocal.delay.seconds", defaultValue: "%lld seconds"), Int(rawValue))
        }
    }

    /// The preset closest to an arbitrary stored delay, for showing an edited rule.
    public static func closest(to seconds: TimeInterval) -> MapLocalDelay? {
        allCases.min { abs($0.rawValue - seconds) < abs($1.rawValue - seconds) }
            .flatMap { abs($0.rawValue - seconds) < 0.5 ? $0 : nil }
    }
}

/// Decides whether a Map Local rule applies to a request.
///
/// Pure comparison; reading the mapped file happens later, in `MapLocalResponder`.
public enum MapLocalMatcher {
    public static func matches(_ rule: MapLocalRule, request: HTTPRequest) -> Bool {
        guard rule.isEnabled, rule.method.matches(request.method) else { return false }
        // A regex keeps its case: `\S`, `\D`, `\W` and `\B` mean the opposite of their
        // lowercase forms, so folding the pattern would silently change what it matches.
        // Regex matching is already case-insensitive, so literals are unaffected.
        let pattern = normalize(rule.url, preservingCase: rule.matchStyle == .regex)
        // An empty pattern would otherwise match the whole world; a rule with nothing
        // written in it is treated as inactive rather than as a catch-all.
        guard !pattern.isEmpty else { return false }
        guard let target = matchTarget(rule, request: request) else { return false }

        switch rule.matchStyle {
        case .contains:
            return target.lowercased().contains(pattern)
        case .wildcard:
            return Wildcard.matches(pattern: pattern, value: target)
        case .regex:
            return fullRegexMatch(pattern: pattern, value: target)
        case .exact:
            return target.lowercased() == pattern
        }
    }

    /// The first enabled rule that matches, in list order.
    public static func firstMatch(in rules: [MapLocalRule], request: HTTPRequest) -> MapLocalRule? {
        rules.first { matches($0, request: request) }
    }

    /// Strip a leading `scheme://` so a pattern copied out of a browser address bar works.
    ///
    /// The pattern is folded to lowercase for the literal styles, whose comparison is
    /// case-insensitive. A regex is left as written, since its escapes are case-sensitive.
    static func normalize(_ pattern: String, preservingCase: Bool = false) -> String {
        var value = pattern.trimmingCharacters(in: .whitespaces)
        if !preservingCase { value = value.lowercased() }
        if let separator = value.range(of: "://") {
            let scheme = value[value.startIndex..<separator.lowerBound]
            if !scheme.isEmpty, scheme.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "+" || $0 == "-" || $0 == "." }) {
                value = String(value[separator.upperBound...])
            }
        }
        return value
    }

    /// The text a pattern is compared against: `host[:port]`, plus the path when asked.
    static func matchTarget(_ rule: MapLocalRule, request: HTTPRequest) -> String? {
        let isDefaultPort = (request.isHTTPS && request.port == 443) || (!request.isHTTPS && request.port == 80)
        var target = isDefaultPort ? request.host.lowercased() : "\(request.host.lowercased()):\(request.port)"
        guard rule.includePath else { return target }
        let path = request.path.hasPrefix("/") ? request.path : "/" + request.path
        target += path
        return target
    }

    /// Regex is anchored on purpose: ProxyMaxx's editor calls this "full-matching regex",
    /// and its own examples spell out the tail as `(.*)` rather than relying on a subset match.
    static func fullRegexMatch(pattern: String, value: String) -> Bool {
        guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else {
            return false
        }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        guard let match = regex.firstMatch(in: value, options: [], range: range) else { return false }
        return match.range == range
    }
}
