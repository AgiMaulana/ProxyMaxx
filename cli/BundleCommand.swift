import Foundation
import RuleKit

enum BundleCommand {
    static func run(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError("bundle needs an action (import|export|activate|deactivate|remove|list|show)")
        }
        let body = arguments.after(action)
        switch action {
        case "import": try await importBundle(body)
        case "export": try await exportBundle(body)
        case "activate", "deactivate", "remove": try await mutate(action, arguments: body)
        case "list": try await list(body)
        case "show": try await show(body)
        default:
            throw CLIError("unknown bundle action '\(action)'", hint: "import|export|activate|deactivate|remove|list|show")
        }
    }

    private static func importBundle(_ arguments: Arguments) async throws {
        guard arguments.positional.count == 1, let input = arguments.positional.first else {
            throw CLIError("bundle import needs one ZIP path, optionally --activate")
        }
        let archiveURL = localURL(input)
        let activate = arguments.has("activate")
        let bundle: MapLocalBundle
        if RuleCommand.appOwned(for: arguments) {
            guard let imported = try await RuleCommand.deliver(
                .importBundle, enabled: activate, archivePath: archiveURL.path
            )?.bundle else {
                throw CLIError("the GUI app did not return the imported bundle")
            }
            bundle = imported
        } else {
            let rulesURL = RuleCommand.resolveRulesFile(arguments)
            var file = try RuleCommand.loadRulesFile(rulesURL)
            bundle = try MapLocalBundleArchive.importBundle(
                from: archiveURL, into: &file, storageDirectory: storageDirectory(for: rulesURL),
                activate: activate, persistTo: rulesURL
            )
        }
        note("imported bundle '\(bundle.name)' with \(bundle.ruleIDs.count) rules\(activate ? "; activated" : "; disabled")")
        try emit(bundle)
    }

    private static func exportBundle(_ arguments: Arguments) async throws {
        guard arguments.positional.count <= 1 else {
            throw CLIError("bundle export accepts at most one imported bundle selector")
        }
        guard let output = arguments.value("output") ?? arguments.value("o"),
              !output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw CLIError("bundle export needs --output ZIP")
        }
        let archiveURL = localURL(output)
        guard (try? FileManager.default.attributesOfItem(atPath: archiveURL.path)) == nil else {
            throw CLIError("output already exists at \(archiveURL.path)", hint: "choose a new output ZIP path")
        }
        let selector = arguments.positional.first
        if selector != nil, arguments.has("include") || arguments.has("name") {
            throw CLIError("--include and --name apply only to fresh exports without a bundle selector")
        }
        let name = (arguments.value("name") ?? archiveURL.deletingPathExtension().lastPathComponent)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard selector != nil || !name.isEmpty else {
            throw CLIError("bundle export needs a nonblank --name or output basename")
        }

        if RuleCommand.appOwned(for: arguments) {
            var selectedIDs: [UUID]?
            if let references = arguments.value("include") {
                let file = try await RuleCommand.mapLocalSnapshot(arguments)
                selectedIDs = try resolveRuleIDs(references, in: file.mapLocalRules)
            }
            _ = try await RuleCommand.deliver(
                .exportBundle, target: selector.map(target), archivePath: archiveURL.path,
                bundleName: selector == nil ? name : nil, ruleIDs: selectedIDs
            )
        } else {
            let file = try RuleCommand.loadRulesFile(RuleCommand.resolveRulesFile(arguments))
            if let selector {
                let bundle = try MapLocalBundleState.resolve(selector, in: file)
                try MapLocalBundleArchive.exportBundle(
                    rules: MapLocalBundleState.rules(in: bundle, from: file),
                    name: bundle.name, id: bundle.id, to: archiveURL
                )
            } else {
                var rules = file.mapLocalRules
                if let references = arguments.value("include") {
                    let ids = Set(try resolveRuleIDs(references, in: rules))
                    rules = rules.filter { ids.contains($0.id) }
                }
                try MapLocalBundleArchive.exportBundle(rules: rules, name: name, to: archiveURL)
            }
        }
        note("exported bundle ZIP to \(archiveURL.path)")
    }

    private static func mutate(_ action: String, arguments: Arguments) async throws {
        guard arguments.positional.count == 1, let selector = arguments.positional.first else {
            throw CLIError("bundle \(action) needs one bundle name, id or slug")
        }
        var file = try await RuleCommand.mapLocalSnapshot(arguments)
        let bundle = try MapLocalBundleState.resolve(selector, in: file)
        let applied: Int
        if RuleCommand.appOwned(for: arguments) {
            let operation: CommandIPC.Operation
            switch action {
            case "activate": operation = .activateBundle
            case "deactivate": operation = .deactivateBundle
            default: operation = .removeBundle
            }
            applied = try await RuleCommand.deliver(
                operation, target: RuleCommand.Selector(id: bundle.id, name: nil, url: nil)
            )?.applied ?? 0
        } else {
            let rulesURL = RuleCommand.resolveRulesFile(arguments)
            switch action {
            case "activate":
                applied = try MapLocalBundleState.activate(id: bundle.id, in: &file)
                try file.write(to: rulesURL)
            case "deactivate":
                applied = try MapLocalBundleState.deactivate(id: bundle.id, in: &file)
                try file.write(to: rulesURL)
            default:
                applied = MapLocalBundleState.rules(in: bundle, from: file).count
                try MapLocalBundleState.remove(
                    id: bundle.id, from: &file, storageDirectory: storageDirectory(for: rulesURL),
                    persistTo: rulesURL
                )
            }
        }
        switch action {
        case "activate": note("bundle '\(bundle.name)' active; \(applied) rules enabled")
        case "deactivate": note("bundle '\(bundle.name)' deactivated; \(applied) member rules disabled")
        default: note("bundle '\(bundle.name)' removed")
        }
    }

    private static func list(_ arguments: Arguments) async throws {
        guard arguments.positional.isEmpty else {
            throw CLIError("bundle list takes no selector; use bundle show SELECTOR")
        }
        let file = try await RuleCommand.mapLocalSnapshot(arguments)
        if arguments.has("text") {
            if file.mapLocalBundles.isEmpty { note("no imported bundles") }
            for bundle in file.mapLocalBundles {
                let rules = MapLocalBundleState.rules(in: bundle, from: file)
                print("\(status(bundle, in: file)) \(bundle.name) (\(rules.count) rules) [\(bundle.id.uuidString)]")
            }
        } else {
            for bundle in file.mapLocalBundles {
                try emitObject(object(bundle, in: file))
            }
        }
    }

    private static func show(_ arguments: Arguments) async throws {
        guard arguments.positional.count == 1, let selector = arguments.positional.first else {
            throw CLIError("bundle show needs one bundle name, id or slug")
        }
        let file = try await RuleCommand.mapLocalSnapshot(arguments)
        let bundle = try MapLocalBundleState.resolve(selector, in: file)
        let rules = MapLocalBundleState.rules(in: bundle, from: file)
        if arguments.has("text") {
            print("\(status(bundle, in: file)) \(bundle.name) [\(bundle.id.uuidString)]")
            for rule in rules {
                print("\(rule.isEnabled ? "on" : "off") \(rule.method.displayName) \(rule.matchStyle.rawValue) \(rule.url) -> \(rule.destination.path)")
            }
        } else {
            var result = object(bundle, in: file)
            result["rules"] = rules.map(MapLocalJSON.object)
            try emitObject(result)
        }
    }

    private static func object(_ bundle: MapLocalBundle, in file: RuleFile) -> [String: Any] {
        let rules = MapLocalBundleState.rules(in: bundle, from: file)
        return [
            "id": bundle.id.uuidString,
            "name": bundle.name,
            "rule_ids": rules.map { $0.id.uuidString },
            "active": file.isMapLocalEnabled && MapLocalBundleState.isActive(bundle, in: file.mapLocalRules),
            "status": status(bundle, in: file),
            "rule_count": rules.count,
            "enabled_count": rules.filter(\.isEnabled).count,
        ]
    }

    private static func status(_ bundle: MapLocalBundle, in file: RuleFile) -> String {
        if file.isMapLocalEnabled && MapLocalBundleState.isActive(bundle, in: file.mapLocalRules) { return "active" }
        let rules = MapLocalBundleState.rules(in: bundle, from: file)
        guard !rules.isEmpty else { return "empty" }
        let enabled = rules.filter(\.isEnabled).count
        if enabled == 0 { return "off" }
        if !file.isMapLocalEnabled { return "tool-disabled" }
        return enabled == rules.count ? "enabled-with-outsiders" : "partly-enabled"
    }

    private static func resolveRuleIDs(_ references: String, in rules: [MapLocalRule]) throws -> [UUID] {
        let references = references.split(separator: ",", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard !references.isEmpty, references.allSatisfy({ !$0.isEmpty }) else {
            throw CLIError("--include needs a comma-separated list of rule names, URLs or ids")
        }
        var selected: Set<UUID> = []
        for reference in references {
            let matches: [MapLocalRule]
            if let id = UUID(uuidString: reference) {
                matches = rules.filter { $0.id == id }
            } else {
                matches = rules.filter {
                    $0.name.caseInsensitiveCompare(reference) == .orderedSame
                        || $0.url.caseInsensitiveCompare(reference) == .orderedSame
                }
            }
            guard matches.count == 1, let rule = matches.first else {
                if matches.isEmpty {
                    throw CLIError("no rule matches '\(reference)'", hint: "run `proxymaxx-cli rule list --text`")
                }
                throw CLIError("rule reference '\(reference)' is ambiguous; use its UUID")
            }
            selected.insert(rule.id)
        }
        return rules.filter { selected.contains($0.id) }.map(\.id)
    }

    private static func target(_ selector: String) -> RuleCommand.Selector {
        if let id = UUID(uuidString: selector) {
            return RuleCommand.Selector(id: id, name: nil, url: nil)
        }
        return RuleCommand.Selector(id: nil, name: selector, url: nil)
    }

    private static func localURL(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath).standardizedFileURL
    }

    private static func storageDirectory(for rulesURL: URL) -> URL {
        rulesURL.deletingLastPathComponent().appendingPathComponent("local-override-bundles", isDirectory: true)
    }

    private static func emit<T: Encodable>(_ value: T) throws {
        let data = try JSONEncoder().encode(value)
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    private static func emitObject(_ object: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }
}
