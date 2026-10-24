import Foundation
import RuleKit

/// `proxymaxx-cli rules <tool> <action>` — the JSON rule surface that mirrors the shipped
/// `proxymaxx-cli`. The verbs (`list`, `get`, `create`, `update`, `delete`, `enable`,
/// `disable`) and the response envelope are ProxyMaxx's; the tool set is ours, so only
/// the tools this build implements answer, and the rest say so in the same envelope
/// instead of failing as an unknown command.
///
/// Reads and writes go through `RuleCommand`'s transport: the app's live engine over
/// `CommandIPC` when the app owns the proxy, the shared rule file otherwise.
enum RulesCommand {
    /// Tools with a working rule set behind them.
    static let supportedTools = ["map-local", "ssl-proxying"]
    /// Every tool the shipped CLI names, so an agent gets the same vocabulary here and a
    /// precise "not in this build" instead of "unknown command" for the rest.
    static let knownTools = supportedTools + [
        "map-remote", "breakpoint", "scripting", "network-condition",
        "reverse-proxy", "block-list", "allow-list", "protobuf", "dns-spoofing",
    ]

    static func run(_ arguments: Arguments) async throws {
        guard let tool = arguments.positional.first else {
            throw CLIError("rules needs a tool", hint: knownTools.joined(separator: "|"))
        }
        guard knownTools.contains(tool) else {
            throw CLIError("unknown tool '\(tool)'", hint: knownTools.joined(separator: "|"))
        }
        let body = arguments.after(tool)
        guard let action = body.positional.first else {
            throw CLIError("rules \(tool) needs an action (list|get|create|update|delete|enable|disable)")
        }
        let rest = body.after(action)

        guard supportedTools.contains(tool) else {
            RulesEnvelope.fail(
                tool: tool,
                action: action,
                code: "unsupported",
                message: "This build has no \(tool) tool yet; only map-local and ssl-proxying are implemented."
            )
        }
        switch tool {
        case "map-local": try await mapLocal(action: action, arguments: rest)
        default: try await sslProxying(action: action, arguments: rest)
        }
    }

    // MARK: - Map Local

    private static func mapLocal(action: String, arguments: Arguments) async throws {
        switch action {
        case "list": try listMapLocal(arguments)
        case "get": try getMapLocal(arguments)
        case "create": try await createMapLocal(arguments)
        case "update": try await updateMapLocal(arguments)
        case "delete": try await deleteMapLocal(arguments)
        case "enable": try await setMapLocalEnabled(arguments, enabled: true)
        case "disable": try await setMapLocalEnabled(arguments, enabled: false)
        default:
            throw CLIError("map-local has no '\(action)' action", hint: "list|get|create|update|delete|enable|disable")
        }
    }

    private static func listMapLocal(_ arguments: Arguments) throws {
        let file = RuleFile.load(from: RuleCommand.resolveRulesFile(arguments))
        var rules = file.mapLocalRules
        if let only = try boolValue(arguments, "enabled") {
            rules = rules.filter { $0.isEnabled == only }
        }
        RulesEnvelope.emit(
            tool: "map-local",
            action: "list",
            data: ["enabled": file.isMapLocalEnabled, "rules": rules.map(MapLocalJSON.object)]
        )
    }

    private static func getMapLocal(_ arguments: Arguments) throws {
        let file = RuleFile.load(from: RuleCommand.resolveRulesFile(arguments))
        guard let id = idArgument(arguments),
              let rule = file.mapLocalRules.first(where: { $0.id == id })
        else {
            RulesEnvelope.fail(tool: "map-local", action: "get", code: "not_found", message: "no rule with that id")
        }
        RulesEnvelope.emit(tool: "map-local", action: "get", data: MapLocalJSON.object(rule))
    }

    /// Build a rule from `--input` and the field flags (flags win), then insert it.
    private static func createMapLocal(_ arguments: Arguments) async throws {
        var rule = MapLocalRule()
        if let input = arguments.value("input") {
            try MapLocalJSON.apply(try readJSONObject(at: input), to: &rule)
        }
        if let url = arguments.positional.first { rule.url = url }
        try applyMapLocalFlags(arguments, to: &rule)

        guard !rule.url.trimmingCharacters(in: .whitespaces).isEmpty else {
            RulesEnvelope.fail(tool: "map-local", action: "create", code: "invalid_input", message: "create needs a URL, e.g. `rules map-local create 'api.example.com/v1/*' --path stub.json`")
        }
        guard !rule.destination.path.isEmpty else {
            RulesEnvelope.fail(tool: "map-local", action: "create", code: "invalid_input", message: "create needs --path pointing at the response to serve")
        }
        try requireReadable(rule.destination.path)

        if RuleCommand.appOwned() {
            rule = try await RuleCommand.deliver(.add, rule: rule)?.rule ?? rule
        } else {
            let url = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: url)
            file.mapLocalRules.append(rule)
            try file.write(to: url)
        }
        RulesEnvelope.emit(tool: "map-local", action: "create", data: MapLocalJSON.object(rule))
    }

    private static func updateMapLocal(_ arguments: Arguments) async throws {
        guard let id = idArgument(arguments) else {
            RulesEnvelope.fail(tool: "map-local", action: "update", code: "invalid_input", message: "update needs a rule id")
        }
        let path = RuleCommand.resolveRulesFile(arguments)
        var file = RuleFile.load(from: path)
        guard let index = file.mapLocalRules.firstIndex(where: { $0.id == id }) else {
            RulesEnvelope.fail(tool: "map-local", action: "update", code: "not_found", message: "no rule with id \(id.uuidString)")
        }
        var rule = file.mapLocalRules[index]
        if let input = arguments.value("input") {
            try MapLocalJSON.apply(try readJSONObject(at: input), to: &rule)
        }
        try applyMapLocalFlags(arguments, to: &rule)
        if !rule.destination.path.isEmpty { try requireReadable(rule.destination.path) }

        if RuleCommand.appOwned() {
            rule = try await RuleCommand.deliver(.update, rule: rule)?.rule ?? rule
        } else {
            file.mapLocalRules[index] = rule
            try file.write(to: path)
        }
        RulesEnvelope.emit(tool: "map-local", action: "update", data: MapLocalJSON.object(rule))
    }

    private static func deleteMapLocal(_ arguments: Arguments) async throws {
        guard let id = idArgument(arguments) else {
            RulesEnvelope.fail(tool: "map-local", action: "delete", code: "invalid_input", message: "delete needs a rule id")
        }
        if RuleCommand.appOwned() {
            _ = try await RuleCommand.deliver(.remove, target: RuleCommand.Selector(id: id, name: nil, url: nil))
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            guard let index = file.mapLocalRules.firstIndex(where: { $0.id == id }) else {
                RulesEnvelope.fail(tool: "map-local", action: "delete", code: "not_found", message: "no rule with id \(id.uuidString)")
            }
            file.mapLocalRules.remove(at: index)
            try file.write(to: path)
        }
        RulesEnvelope.emit(tool: "map-local", action: "delete", data: ["id": id.uuidString])
    }

    /// `enable`/`disable` with an id flips one rule; without one it flips the tool switch,
    /// which is what `maplocal on|off` and the shipped CLI both do.
    private static func setMapLocalEnabled(_ arguments: Arguments, enabled: Bool) async throws {
        if let id = idArgument(arguments) {
            if RuleCommand.appOwned() {
                _ = try await RuleCommand.deliver(enabled ? .enable : .disable, target: RuleCommand.Selector(id: id, name: nil, url: nil))
            } else {
                let path = RuleCommand.resolveRulesFile(arguments)
                var file = RuleFile.load(from: path)
                guard let index = file.mapLocalRules.firstIndex(where: { $0.id == id }) else {
                    RulesEnvelope.fail(tool: "map-local", action: enabled ? "enable" : "disable", code: "not_found", message: "no rule with id \(id.uuidString)")
                }
                file.mapLocalRules[index].isEnabled = enabled
                try file.write(to: path)
            }
            RulesEnvelope.emit(tool: "map-local", action: enabled ? "enable" : "disable", data: ["id": id.uuidString, "enabled": enabled])
            return
        }
        try await setToolSwitch(fileTool: "map-local", enabled: enabled, arguments: arguments)
        RulesEnvelope.emit(tool: "map-local", action: enabled ? "enable" : "disable", data: ["enabled": enabled])
    }

    private static func applyMapLocalFlags(_ arguments: Arguments, to rule: inout MapLocalRule) throws {
        if let name = arguments.value("name") { rule.name = name }
        if let method = arguments.value("method") { rule.method = MethodMatch(method) }
        if let match = arguments.value("match") {
            guard let style = URLMatchStyle(rawValue: match) else {
                RulesEnvelope.fail(tool: "map-local", action: "create", code: "invalid_input", message: "match must be contains|wildcard|regex|exact")
            }
            rule.matchStyle = style
        }
        if let enabled = try boolValue(arguments, "enabled") { rule.isEnabled = enabled }
        if let include = try boolValue(arguments, "include-subpaths") { rule.includePath = include }
        if let delay = arguments.value("delay-ms").flatMap(Int.init) {
            guard delay >= 0 else {
                RulesEnvelope.fail(tool: "map-local", action: "create", code: "invalid_input", message: "--delay-ms must be 0 or greater")
            }
            rule.responseDelay = Double(delay) / 1000
        }
        if let path = arguments.value("path") {
            let kind = arguments.value("kind") ?? (rule.destination.isFile ? "file" : "directory")
            let expanded = MapLocalJSON.expanded(path)
            rule.destination = kind == "directory" ? .directory(expanded) : .file(expanded)
        }
    }

    // MARK: - SSL Proxying

    private static func sslProxying(action: String, arguments: Arguments) async throws {
        switch action {
        case "list": try listSSLProxying(arguments)
        case "create", "update": try await mutateSSLProxying(arguments, action: action, add: true)
        case "delete": try await mutateSSLProxying(arguments, action: action, add: false)
        case "enable": try await setToolSwitch(fileTool: "ssl-proxying", enabled: true, arguments: arguments)
        case "disable": try await setToolSwitch(fileTool: "ssl-proxying", enabled: false, arguments: arguments)
        default:
            throw CLIError("ssl-proxying has no '\(action)' action", hint: "list|create|update|delete|enable|disable")
        }
    }

    private static func listSSLProxying(_ arguments: Arguments) throws {
        let file = RuleFile.load(from: RuleCommand.resolveRulesFile(arguments))
        RulesEnvelope.emit(
            tool: "ssl-proxying",
            action: "list",
            data: [
                "enabled": file.isSSLProxyingEnabled,
                "include": file.sslProxyingPolicy.include,
                "exclude": file.sslProxyingPolicy.exclude,
            ]
        )
    }

    /// SSL Proxying has no per-rule ids in this build; the unit of change is one
    /// include/exclude pattern, named by `--list` and `--pattern`.
    private static func mutateSSLProxying(_ arguments: Arguments, action: String, add: Bool) async throws {
        guard let list = arguments.value("list"), list == "include" || list == "exclude" else {
            RulesEnvelope.fail(tool: "ssl-proxying", action: action, code: "invalid_input", message: "--list must be include or exclude")
        }
        guard let pattern = arguments.value("pattern"), !pattern.isEmpty else {
            RulesEnvelope.fail(tool: "ssl-proxying", action: action, code: "invalid_input", message: "\(action) needs --pattern")
        }
        if RuleCommand.appOwned() {
            _ = try await RuleCommand.deliver(.setSSLProxying, list: list, pattern: pattern, add: add)
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            var policy = file.sslProxyingPolicy
            switch list {
            case "include":
                policy.include.removeAll { $0 == pattern }
                if add { policy.include.append(pattern) }
            default:
                policy.exclude.removeAll { $0 == pattern }
                if add { policy.exclude.append(pattern) }
            }
            file.sslProxyingPolicy = policy
            try file.write(to: path)
        }
        RulesEnvelope.emit(tool: "ssl-proxying", action: action, data: ["list": list, "pattern": pattern, "add": add])
    }

    // MARK: - Shared

    /// Flip a whole-tool master switch, over IPC when the app owns the engine and in the
    /// shared rule file otherwise. Both transports end in identical engine state.
    static func setToolSwitch(fileTool: String, enabled: Bool, arguments: Arguments) async throws {
        if RuleCommand.appOwned() {
            _ = try await RuleCommand.deliver(.setToolEnabled, tool: fileTool, enabled: enabled)
        } else {
            let path = RuleCommand.resolveRulesFile(arguments)
            var file = RuleFile.load(from: path)
            switch fileTool {
            case "map-local": file.isMapLocalEnabled = enabled
            default: file.isSSLProxyingEnabled = enabled
            }
            try file.write(to: path)
        }
    }

    /// The positional id after the action, when present and well-formed.
    private static func idArgument(_ arguments: Arguments) -> UUID? {
        arguments.positional.first.flatMap(UUID.init)
    }

    private static func requireReadable(_ path: String) throws {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDirectory) else {
            RulesEnvelope.fail(tool: "map-local", action: "create", code: "invalid_input", message: "no file or directory at \(path)")
        }
    }
}
