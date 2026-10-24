import Foundation

/// A named set of Map Local rules that can be turned on together.
///
/// A scenario holds rule identifiers rather than patterns, so renaming a rule does not
/// break it, and a rule deleted since the scenario was captured is simply skipped.
public struct MapLocalScenario: Identifiable, Codable, Hashable, Sendable {
    public var id: UUID
    public var name: String
    /// The rules this scenario turns on, in the order they were captured.
    public var ruleIDs: [UUID]

    public init(id: UUID = UUID(), name: String = "", ruleIDs: [UUID] = []) {
        self.id = id
        self.name = name
        self.ruleIDs = ruleIDs
    }

    /// The name shown in the picker; an unnamed scenario falls back to its identifier.
    public var displayName: String {
        let trimmed = name.trimmingCharacters(in: .whitespaces)
        return trimmed.isEmpty ? id.uuidString : trimmed
    }
}

/// One rule taking another's place in a scenario because both answer the same endpoint.
///
/// The editor prevents this from happening silently: it warns before saving and offers an
/// undo afterwards, so a replacement is always a deliberate choice or a reversible one.
public struct MapLocalScenarioSwap: Equatable, Sendable {
    public let scenarioID: UUID
    public let scenarioName: String
    public let addedRuleID: UUID
    public let replacedRuleID: UUID
    public let replacedRuleName: String

    public init(
        scenarioID: UUID,
        scenarioName: String,
        addedRuleID: UUID,
        replacedRuleID: UUID,
        replacedRuleName: String
    ) {
        self.scenarioID = scenarioID
        self.scenarioName = scenarioName
        self.addedRuleID = addedRuleID
        self.replacedRuleID = replacedRuleID
        self.replacedRuleName = replacedRuleName
    }
}

/// Applies a scenario to the rule list.
///
/// Activation is exclusive: the scenario's rules are turned on and every other rule is
/// turned off. One click therefore gives a reproducible set, which is the point of a test
/// scenario — a rule left over from the previous setup must not answer a request.
public enum MapLocalScenarioRunner {
    /// Turn on exactly `scenario`'s rules. Returns how many existing rules were enabled;
    /// identifiers with no matching rule are ignored rather than failing the activation.
    @discardableResult
    public static func activate(_ scenario: MapLocalScenario, in rules: inout [MapLocalRule]) -> Int {
        let wanted = Set(scenario.ruleIDs)
        var enabled = 0
        for index in rules.indices {
            let isMember = wanted.contains(rules[index].id)
            rules[index].isEnabled = isMember
            if isMember { enabled += 1 }
        }
        return enabled
    }

    /// True when the rules on screen are exactly what this scenario would turn on.
    public static func isActive(_ scenario: MapLocalScenario, in rules: [MapLocalRule]) -> Bool {
        let wanted = Set(scenario.ruleIDs)
        return rules.allSatisfy { $0.isEnabled == wanted.contains($0.id) }
    }
}
