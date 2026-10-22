import Foundation
import FlowKit

/// Which part of a request a condition inspects.
public enum MatchField: String, Codable, Sendable, CaseIterable {
    case method
    case host
    case port
    case path
    case query
    case url
    case header
    case body

    public var displayName: String {
        switch self {
        case .method: return String(localized: "common.method", defaultValue: "Method")
        case .host: return String(localized: "common.host", defaultValue: "Host")
        case .port: return String(localized: "common.port", defaultValue: "Port")
        case .path: return String(localized: "common.path", defaultValue: "Path")
        case .query: return String(localized: "common.query", defaultValue: "Query")
        case .url: return String(localized: "common.url", defaultValue: "URL")
        case .header: return String(localized: "common.header", defaultValue: "Header")
        case .body: return String(localized: "common.body", defaultValue: "Body")
        }
    }
}

/// How a condition compares the field against its value.
public enum MatchOperator: String, Codable, Sendable, CaseIterable {
    case equals
    case notEquals
    case contains
    case notContains
    case startsWith
    case endsWith
    case wildcard
    case regex
    case exists

    public var displayName: String {
        switch self {
        case .equals: return String(localized: "rule.op.equals", defaultValue: "equals")
        case .notEquals: return String(localized: "rule.op.notEquals", defaultValue: "not equals")
        case .contains: return String(localized: "rule.op.contains", defaultValue: "contains")
        case .notContains: return String(localized: "rule.op.notContains", defaultValue: "not contains")
        case .startsWith: return String(localized: "rule.op.startsWith", defaultValue: "starts with")
        case .endsWith: return String(localized: "rule.op.endsWith", defaultValue: "ends with")
        case .wildcard: return String(localized: "rule.op.wildcard", defaultValue: "matches wildcard")
        case .regex: return String(localized: "rule.op.regex", defaultValue: "matches regex")
        case .exists: return String(localized: "rule.op.exists", defaultValue: "exists")
        }
    }
}

/// A single comparison within a matching rule.
public struct MatchCondition: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var field: MatchField
    /// Header name when `field == .header`.
    public var name: String
    public var op: MatchOperator
    public var value: String
    public var caseSensitive: Bool

    public init(
        id: UUID = UUID(),
        field: MatchField = .host,
        name: String = "",
        op: MatchOperator = .contains,
        value: String = "",
        caseSensitive: Bool = false
    ) {
        self.id = id
        self.field = field
        self.name = name
        self.op = op
        self.value = value
        self.caseSensitive = caseSensitive
    }
}

/// How multiple conditions combine.
public enum MatchLogic: String, Codable, Sendable {
    case and
    case or
}

/// A reusable rule: a set of conditions combined with AND/OR.
public struct MatchingRule: Codable, Sendable, Hashable, Identifiable {
    public var id: UUID
    public var name: String
    public var isEnabled: Bool
    public var logic: MatchLogic
    public var conditions: [MatchCondition]

    public init(
        id: UUID = UUID(),
        name: String = "",
        isEnabled: Bool = true,
        logic: MatchLogic = .and,
        conditions: [MatchCondition] = []
    ) {
        self.id = id
        self.name = name
        self.isEnabled = isEnabled
        self.logic = logic
        self.conditions = conditions
    }
}

/// Evaluates matching rules against captured requests.
public enum RuleMatcher {
    public static func matches(_ rule: MatchingRule, request: HTTPRequest) -> Bool {
        guard rule.isEnabled, !rule.conditions.isEmpty else { return false }
        switch rule.logic {
        case .and:
            return rule.conditions.allSatisfy { matches($0, request: request) }
        case .or:
            return rule.conditions.contains { matches($0, request: request) }
        }
    }

    public static func matches(_ condition: MatchCondition, request: HTTPRequest) -> Bool {
        let candidates = values(for: condition, request: request)
        switch condition.op {
        case .exists:
            return !candidates.isEmpty && !(candidates.count == 1 && candidates[0].isEmpty)
        default:
            return candidates.contains { compare(condition, candidate: $0) }
        }
    }

    private static func values(for condition: MatchCondition, request: HTTPRequest) -> [String] {
        switch condition.field {
        case .method: return [request.method]
        case .host: return [request.host]
        case .port: return [String(request.port)]
        case .path: return [request.pathWithoutQuery]
        case .query: return [request.query ?? ""]
        case .url: return [request.urlString]
        case .header:
            return condition.name.isEmpty ? request.headers.entries.map(\.value) : request.headers.allValues(for: condition.name)
        case .body:
            return [BodyFormatting.text(from: request.body, contentType: request.contentType) ?? ""]
        }
    }

    private static func compare(_ condition: MatchCondition, candidate: String) -> Bool {
        let lhs = condition.caseSensitive ? candidate : candidate.lowercased()
        let rhs = condition.caseSensitive ? condition.value : condition.value.lowercased()
        switch condition.op {
        case .equals: return lhs == rhs
        case .notEquals: return lhs != rhs
        case .contains: return lhs.contains(rhs)
        case .notContains: return !lhs.contains(rhs)
        case .startsWith: return lhs.hasPrefix(rhs)
        case .endsWith: return lhs.hasSuffix(rhs)
        case .wildcard: return Wildcard.matches(pattern: rhs, value: lhs, caseSensitive: true)
        case .regex:
            guard let regex = try? NSRegularExpression(pattern: condition.value, options: condition.caseSensitive ? [] : [.caseInsensitive]) else {
                return false
            }
            let range = NSRange(candidate.startIndex..<candidate.endIndex, in: candidate)
            return regex.firstMatch(in: candidate, options: [], range: range) != nil
        case .exists:
            return !candidate.isEmpty
        }
    }
}
