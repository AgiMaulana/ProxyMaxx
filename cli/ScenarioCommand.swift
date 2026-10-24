import Foundation
import RuleKit

/// `proxymaxx-cli scenario <action>` — named sets of Map Local rules turned on together.
///
/// A scenario is stored in the same `rules.json` the app writes, so activating one from a
/// shell and opening the app show the same rule switches. While the GUI app owns the
/// engine the file is the app's autosave, so reads and writes travel over `CommandIPC`
/// instead of racing the debounce.
enum ScenarioCommand {
    static func run(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError("scenario needs an action (list|show|create|delete|activate)")
        }
        let body = arguments.after(action)
        switch action {
        case "list": try await list(body)
        case "show": try await show(body)
        case "create": try await create(body)
        case "delete": try await remove(body)
        case "activate": try await activate(body)
        default:
            throw CLIError("unknown scenario action '\(action)'", hint: "list|show|create|delete|activate")
        }
    }

    /// The live scenarios and rules: the app's in-memory store when it owns the engine,
    /// the rule file otherwise. Reading the file while the app owns it would show state
    /// from before the last debounced save, which breaks create-then-activate in one shell.
    private struct Snapshot {
        var scenarios: [MapLocalScenario]
        var rules: [MapLocalRule]
    }

    private static func snapshot(_ arguments: Arguments) async throws -> Snapshot {
        guard RuleCommand.appOwned() else {
            let file = RuleFile.load(from: RuleCommand.resolveRulesFile(arguments))
            return Snapshot(scenarios: file.mapLocalScenarios, rules: file.mapLocalRules)
        }
        guard let result = try await RuleCommand.deliver(.listScenarios) else {
            throw CLIError("the GUI app owns the proxy but did not answer the scenario read")
        }
        return Snapshot(scenarios: result.scenarios ?? [], rules: result.rules ?? [])
    }

    private static func list(_ arguments: Arguments) async throws {
        let snapshot = try await snapshot(arguments)
        let existing = Set(snapshot.rules.map(\.id))
        if arguments.has("text") {
            if snapshot.scenarios.isEmpty {
                note("no scenarios in \(RuleCommand.appOwned() ? "the app" : RuleCommand.resolveRulesFile(arguments).path)")
            }
            for scenario in snapshot.scenarios {
                let enabled = MapLocalScenarioRunner.isActive(scenario, in: snapshot.rules)
                let count = scenario.ruleIDs.filter { existing.contains($0) }.count
                print("\(enabled ? "on " : "off") \(scenario.name) (\(count) rule\(count == 1 ? "" : "s"))")
            }
            return
        }
        for scenario in snapshot.scenarios {
            let object: [String: Any] = [
                "id": scenario.id.uuidString,
                "name": scenario.name,
                "rule_ids": scenario.ruleIDs.map(\.uuidString),
                "active": MapLocalScenarioRunner.isActive(scenario, in: snapshot.rules),
            ]
            let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
            FileHandle.standardOutput.write(data)
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    private static func show(_ arguments: Arguments) async throws {
        guard let selector = arguments.positional.first else {
            throw CLIError("scenario show needs a scenario name or id")
        }
        let snapshot = try await snapshot(arguments)
        guard let scenario = resolve(selector, in: snapshot.scenarios) else {
            throw CLIError("no scenario named '\(selector)'", hint: "run `proxymaxx-cli scenario list`")
        }
        let known = Dictionary(uniqueKeysWithValues: snapshot.rules.map { ($0.id, $0) })
        let rules = scenario.ruleIDs.compactMap { known[$0] }.map { rule in
            [
                "id": rule.id.uuidString,
                "name": rule.name,
                "url": rule.url,
                "enabled": rule.isEnabled,
            ] as [String: Any]
        }
        let object: [String: Any] = [
            "id": scenario.id.uuidString,
            "name": scenario.name,
            "active": MapLocalScenarioRunner.isActive(scenario, in: snapshot.rules),
            "rules": rules,
        ]
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        print(String(decoding: data, as: UTF8.self))
    }

    /// `scenario create --name "visit flow" --include consultation,prescription`
    ///
    /// `--include` rather than `--rules`, because `--rules` already names the rule file.
    /// Rule references are matched against a name, URL or id, so a scenario can be written
    /// from whatever the caller already knows. An unknown reference fails before anything
    /// is saved.
    private static func create(_ arguments: Arguments) async throws {
        guard let name = arguments.value("name")?.trimmingCharacters(in: .whitespaces), !name.isEmpty else {
            throw CLIError("scenario create needs --name")
        }
        guard let references = arguments.value("include"), !references.isEmpty else {
            throw CLIError("scenario create needs --include", hint: "a comma-separated list of rule names, URLs or ids")
        }

        let snapshot = try await snapshot(arguments)
        var ids: [UUID] = []
        var unknown: [String] = []
        for reference in references.split(separator: ",").map({ $0.trimmingCharacters(in: .whitespaces) }) where !reference.isEmpty {
            if let rule = resolveRule(reference, in: snapshot.rules) {
                if !ids.contains(rule.id) { ids.append(rule.id) }
            } else {
                unknown.append(reference)
            }
        }
        guard unknown.isEmpty else {
            throw CLIError(
                "no rule matches \(unknown.map { "'\($0)'" }.joined(separator: ", "))",
                hint: "run `proxymaxx-cli rule list --text` to see rule names and URLs"
            )
        }
        guard !ids.isEmpty else {
            throw CLIError("scenario create needs at least one rule")
        }

        var scenario = MapLocalScenario(name: name, ruleIDs: ids)
        if RuleCommand.appOwned() {
            // A same-name capture replaces the existing scenario, keeping its identifier.
            if let existing = snapshot.scenarios.first(where: { $0.name.caseInsensitiveCompare(name) == .orderedSame }) {
                scenario.id = existing.id
            }
            _ = try await RuleCommand.deliver(.addScenario, scenario: scenario)
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            if let index = file.mapLocalScenarios.firstIndex(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                scenario.id = file.mapLocalScenarios[index].id
                file.mapLocalScenarios[index] = scenario
            } else {
                file.mapLocalScenarios.append(scenario)
            }
            try file.write(to: path)
        }
        note("scenario '\(name)' saved with \(ids.count) rule\(ids.count == 1 ? "" : "s")")
    }

    private static func remove(_ arguments: Arguments) async throws {
        guard let selector = arguments.positional.first else {
            throw CLIError("scenario delete needs a scenario name or id")
        }
        let snapshot = try await snapshot(arguments)
        guard let scenario = resolve(selector, in: snapshot.scenarios) else {
            throw CLIError("no scenario named '\(selector)'")
        }
        if RuleCommand.appOwned() {
            _ = try await RuleCommand.deliver(
                .removeScenario,
                target: RuleCommand.Selector(id: scenario.id, name: scenario.name, url: nil)
            )
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            file.mapLocalScenarios.removeAll { $0.id == scenario.id }
            try file.write(to: path)
        }
        note("scenario '\(scenario.name)' deleted")
    }

    /// Turn on exactly the scenario's rules; every other rule goes off, for a reproducible set.
    private static func activate(_ arguments: Arguments) async throws {
        guard let selector = arguments.positional.first else {
            throw CLIError("scenario activate needs a scenario name or id")
        }
        let snapshot = try await snapshot(arguments)
        guard let scenario = resolve(selector, in: snapshot.scenarios) else {
            throw CLIError("no scenario named '\(selector)'")
        }

        if RuleCommand.appOwned() {
            let result = try await RuleCommand.deliver(
                .activateScenario,
                target: RuleCommand.Selector(id: scenario.id, name: scenario.name, url: nil)
            )
            let applied = result?.applied ?? 0
            note("scenario '\(scenario.name)' active; \(applied) rule\(applied == 1 ? "" : "s") enabled")
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            let applied = MapLocalScenarioRunner.activate(scenario, in: &file.mapLocalRules)
            try file.write(to: path)
            let stale = scenario.ruleIDs.count - applied
            note("scenario '\(scenario.name)' active; \(applied) rule\(applied == 1 ? "" : "s") enabled")
            if stale > 0 {
                print("warning: \(stale) rule\(stale == 1 ? "" : "s") in this scenario no longer exist")
            }
        }
    }

    // MARK: - Helpers

    private static func resolve(_ selector: String, in scenarios: [MapLocalScenario]) -> MapLocalScenario? {
        if let id = UUID(uuidString: selector) {
            return scenarios.first { $0.id == id }
        }
        return scenarios.first { $0.name.caseInsensitiveCompare(selector) == .orderedSame }
    }

    /// Name first, then URL, then id — the order a human is likely to try them.
    private static func resolveRule(_ reference: String, in rules: [MapLocalRule]) -> MapLocalRule? {
        if let rule = rules.first(where: { $0.name.caseInsensitiveCompare(reference) == .orderedSame }) {
            return rule
        }
        if let rule = rules.first(where: { $0.url.caseInsensitiveCompare(reference) == .orderedSame }) {
            return rule
        }
        guard let id = UUID(uuidString: reference) else { return nil }
        return rules.first { $0.id == id }
    }
}
