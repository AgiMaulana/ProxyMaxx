import Foundation
import RuleKit
import Branding

/// CRUD for Map Local rules. The CLI edits the same `RuleFile` JSON the app's RuleStore
/// persists, so there is one schema and one file forever.
///
/// When the GUI app owns the running engine, edits go to the app instead — a request
/// file under `Application Support/ProxyMaxx/ipc/` that the app consumes live —
/// because the app, not the file, is what the engine serves. With no app engine,
/// edits go to the rule file directly; `proxymaxx-cli serve` watches it and reloads.
enum RuleCommand {
    /// Same default location the GUI app uses; `--rules PATH` overrides everywhere.
    static var defaultRulesFile: URL {
        Brand.supportDirectory.appendingPathComponent("rules.json")
    }

    static func resolveRulesFile(_ arguments: Arguments) -> URL {
        guard let path = arguments.value("rules") else { return defaultRulesFile }
        let expanded = (path as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded)
    }

    static func run(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError("rule needs an action (list|add|remove|enable|disable|move|clear). Run `proxymaxx-cli --help`.")
        }
        let body = arguments.after(action)
        switch action {
        case "list":
            try list(body)
        case "add":
            try await add(body)
        case "remove":
            try await remove(body)
        case "enable":
            try await setEnabled(body, enabled: true)
        case "disable":
            try await setEnabled(body, enabled: false)
        case "move":
            try await move(body)
        case "clear":
            try await clear(body)
        default:
            throw CLIError("unknown rule action '\(action)'", hint: "list|add|remove|enable|disable|move|clear")
        }
    }

    // MARK: - attach mode

    /// The GUI app's engine, when it owns the proxy right now. In that case the file is
    /// the app's own autosave — the CLI must not fight it, and mutations travel by
    /// request file so the app applies them to its live engine itself.
    static func appOwned() -> Bool {
        ProxyRegistry.read()?.owner == .app
    }

    /// Ship one mutation to the GUI app and wait for its answer. The wire payload is
    /// the same `MapLocalRule` the file stores, so both transports produce identical
    /// engine state.
    static func deliver(
        _ op: CommandIPC.Operation,
        rule: MapLocalRule? = nil,
        target: Selector? = nil,
        by: Int? = nil,
        tool: String? = nil,
        enabled: Bool? = nil,
        list: String? = nil,
        pattern: String? = nil,
        add: Bool? = nil
    ) async throws -> MapLocalRule? {
        let message = CommandIPC.Message(
            op: op,
            rule: rule,
            targetID: target?.id.map(\.uuidString),
            targetName: target?.name,
            targetURL: target?.url,
            by: by,
            tool: tool,
            enabled: enabled,
            list: list,
            pattern: pattern,
            add: add
        )
        guard let result = CommandIPC.request(message, timeout: 8) else {
            throw CLIError("the GUI app owns the proxy but did not respond within 8s — is it still open? (check: proxymaxx-cli status)")
        }
        guard result.ok else {
            throw CLIError(result.error ?? "command rejected by the GUI app")
        }
        return result.rule
    }

    // MARK: - list

    /// NDJSON rule objects by default; `--text` gives a human one-line-per-rule summary.
    ///
    /// Reads the file even when the app owns the engine: the app autosaves every change
    /// within its debounce window, so the file is as live as the engine.
    private static func list(_ arguments: Arguments) throws {
        let file = RuleFile.load(from: resolveRulesFile(arguments))
        if arguments.has("text") {
            if file.mapLocalRules.isEmpty { note("no map local rules in \(resolveRulesFile(arguments).path)") }
            for rule in file.mapLocalRules {
                let state = rule.isEnabled ? "on" : "off"
                let method = rule.method.isAny ? "" : "\(rule.method.displayName) "
                print("\(state) \(method)\(rule.matchStyle.rawValue) \(rule.url) → \(rule.destination.path)")
            }
            return
        }
        let encoder = JSONEncoder()
        for rule in file.mapLocalRules {
            let data = try encoder.encode(rule)
            FileHandle.standardOutput.write(Data(data))
            FileHandle.standardOutput.write(Data("\n".utf8))
        }
    }

    // MARK: - add

    private static func add(_ arguments: Arguments) async throws {
        let rulesFile = resolveRulesFile(arguments)
        guard let pattern = arguments.value("url"), pattern.trimmingCharacters(in: .whitespaces).isEmpty == false else {
            throw CLIError("rule add needs --url, e.g. --url 'api.example.com/v1/*'")
        }
        guard let filePath = arguments.value("file"), filePath.isEmpty == false else {
            throw CLIError("rule add needs --file pointing at the response to serve")
        }
        let expanded = (filePath as NSString).expandingTildeInPath
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: expanded, isDirectory: &isDirectory), !isDirectory.boolValue else {
            throw CLIError("--file must name a readable file, not: \(expanded)")
        }
        let style: URLMatchStyle
        if let raw = arguments.value("style") {
            guard let parsed = URLMatchStyle(rawValue: raw) else {
                throw CLIError("--style must be one of contains|wildcard|regex|exact")
            }
            style = parsed
        } else {
            style = .wildcard
        }
        let delay = arguments.value("delay").flatMap(Double.init) ?? 0
        guard delay >= 0 else {
            throw CLIError("--delay must be 0 or greater")
        }

        var rule = MapLocalRule(
            name: arguments.value("name") ?? "",
            isEnabled: true,
            method: MethodMatch(arguments.value("method") ?? ""),
            url: pattern,
            matchStyle: style,
            includePath: arguments.has("host-only") ? false : true,
            destination: .file(expanded),
            responseDelay: delay
        )
        if rule.name.isEmpty { rule.name = "cli \(pattern)" }

        if appOwned() {
            let applied = try await deliver(.add, rule: rule)
            try emitRule(applied ?? rule)
            return
        }

        var file = RuleFile.load(from: rulesFile)
        file.mapLocalRules.append(rule)
        try file.write(to: rulesFile)
        note("added rule \(rule.id.uuidString) → \(expanded)")
        try emitRule(rule)
    }

    private static func emitRule(_ rule: MapLocalRule) throws {
        let data = try JSONEncoder().encode(rule)
        FileHandle.standardOutput.write(Data(data))
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    // MARK: - remove / enable / disable / move / clear

    private static func remove(_ arguments: Arguments) async throws {
        guard let target = target(from: arguments) else {
            throw CLIError("rule remove needs --id, --name or --url", hint: "run `proxymaxx-cli rule list` to find one")
        }
        if appOwned() {
            _ = try await deliver(.remove, target: target)
            return
        }
        try await mutate(resolveRulesFile(arguments)) { file in
            let matched = IndexSet(file.mapLocalRules.indices.filter { target.matches(file.mapLocalRules[$0]) })
            guard !matched.isEmpty else {
                throw CLIError("no rule matches \(target.description)")
            }
            file.mapLocalRules = file.mapLocalRules.enumerated()
                .filter { !matched.contains($0.offset) }
                .map { $0.element }
            note("removed \(matched.count) rule\(matched.count == 1 ? "" : "s")")
        }
    }

    private static func setEnabled(_ arguments: Arguments, enabled: Bool) async throws {
        guard let target = target(from: arguments) else {
            throw CLIError("\(enabled ? "enabling" : "disabling") a rule needs --id, --name or --url", hint: "run `proxymaxx-cli rule list` to find one")
        }
        if appOwned() {
            _ = try await deliver(enabled ? .enable : .disable, target: target)
            return
        }
        try await mutate(resolveRulesFile(arguments)) { file in
            let matched = IndexSet(file.mapLocalRules.indices.filter { target.matches(file.mapLocalRules[$0]) })
            guard !matched.isEmpty else {
                throw CLIError("no rule matches \(target.description)")
            }
            for index in matched { file.mapLocalRules[index].isEnabled = enabled }
            note("\(enabled ? "enabled" : "disabled") \(matched.count) rule\(matched.count == 1 ? "" : "s")")
        }
    }

    private static func move(_ arguments: Arguments) async throws {
        guard let id = id(from: arguments) else {
            throw CLIError("rule move needs --id, and --by with a signed offset like -1 or 1")
        }
        let offset = arguments.value("by").flatMap(Int.init) ?? 1
        guard offset != 0 else {
            throw CLIError("--by must not be 0")
        }
        if appOwned() {
            _ = try await deliver(.move, target: Selector(id: id, name: nil, url: nil), by: offset)
            return
        }
        try await mutate(resolveRulesFile(arguments)) { file in
            guard let index = file.mapLocalRules.firstIndex(where: { $0.id == id }) else {
                throw CLIError("no rule with id \(id)")
            }
            let target = index + offset
            guard file.mapLocalRules.indices.contains(target) else {
                throw CLIError("offset \(offset) lands outside the rule list (size \(file.mapLocalRules.count))")
            }
            file.mapLocalRules.swapAt(index, target)
            note("moved rule \(id) by \(offset); it now sits at position \(target)")
        }
    }

    private static func clear(_ arguments: Arguments) async throws {
        if appOwned() {
            _ = try await deliver(.clear)
            return
        }
        let rulesFile = resolveRulesFile(arguments)
        var file = RuleFile.load(from: rulesFile)
        let count = file.mapLocalRules.count
        guard count > 0 else {
            note("nothing to clear — no map local rules in \(rulesFile.path)")
            return
        }
        file.mapLocalRules.removeAll()
        try file.write(to: rulesFile)
        note("cleared \(count) rule\(count == 1 ? "" : "s")")
    }

    // MARK: - helpers

    /// Read, mutate and rewrite the rule file, preserving switches and policy untouched.
    static func mutate(_ rulesFile: URL, _ change: (inout RuleFile) async throws -> Void) async throws {
        var file = RuleFile.load(from: rulesFile)
        try await change(&file)
        try file.write(to: rulesFile)
    }

    /// Which rules a selector picks — by identifier, display name or URL pattern.
    struct Selector {
        var id: UUID?
        var name: String?
        var url: String?

        var description: String {
            if let id { return "id \(id)" }
            if let name { return "name '\(name)'" }
            if let url { return "url '\(url)'" }
            return "(none)"
        }

        func matches(_ rule: MapLocalRule) -> Bool {
            if let id, rule.id == id { return true }
            if let name, rule.name.caseInsensitiveCompare(name) == .orderedSame { return true }
            if let url, rule.url.caseInsensitiveCompare(url) == .orderedSame { return true }
            return false
        }
    }

    private static func target(from arguments: Arguments) -> Selector? {
        let selector = Selector(
            id: id(from: arguments),
            name: arguments.value("name"),
            url: arguments.value("url")
        )
        return selector.id == nil && selector.name == nil && selector.url == nil ? nil : selector
    }

    private static func id(from arguments: Arguments) -> UUID? {
        arguments.value("id").flatMap(UUID.init)
    }
}
