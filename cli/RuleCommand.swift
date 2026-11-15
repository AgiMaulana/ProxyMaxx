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
            throw CLIError("rule needs an action (list|add|import-har|template|remove|enable|disable|move|clear). Run `proxymaxx-cli --help`.")
        }
        let body = arguments.after(action)
        switch action {
        case "list":
            try await list(body)
        case "add":
            try await add(body)
        case "import-har":
            try await importHar(body)
        case "template":
            try template(body)
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
            throw CLIError("unknown rule action '\(action)'", hint: "list|add|import-har|template|remove|enable|disable|move|clear")
        }
    }

    // MARK: - attach mode

    /// The GUI app's engine, when it owns the proxy right now. In that case the file is
    /// the app's own autosave — the CLI must not fight it, and mutations travel by
    /// request file so the app applies them to its live engine itself.
    static func appOwned() -> Bool {
        ProxyRegistry.read()?.owner == .app
    }

    static func appOwned(for arguments: Arguments) -> Bool {
        !arguments.has("rules") && appOwned()
    }

    static func loadRulesFile(_ url: URL) throws -> RuleFile {
        let data: Data
        do {
            data = try Data(contentsOf: url)
        } catch let error as CocoaError where error.code == .fileReadNoSuchFile {
            return RuleFile()
        } catch {
            throw CLIError("cannot read rules file at \(url.path): \(error.localizedDescription)")
        }
        do {
            return try JSONDecoder().decode(RuleFile.self, from: data)
        } catch {
            throw CLIError("invalid rules file at \(url.path): \(error.localizedDescription)")
        }
    }

    static func mapLocalSnapshot(_ arguments: Arguments) async throws -> RuleFile {
        guard appOwned(for: arguments) else {
            return try loadRulesFile(resolveRulesFile(arguments))
        }
        guard let result = try await deliver(.listBundles),
              let bundles = result.bundles, let rules = result.rules else {
            throw CLIError("the GUI app did not return its live Map Local rules and bundles")
        }
        return RuleFile(
            isMapLocalEnabled: result.isMapLocalEnabled ?? true,
            mapLocalRules: rules, mapLocalBundles: bundles
        )
    }

    static func pruneBundleMembership(in file: inout RuleFile) {
        let existing = Set(file.mapLocalRules.map(\.id))
        for index in file.mapLocalBundles.indices {
            file.mapLocalBundles[index].ruleIDs.removeAll { !existing.contains($0) }
        }
    }

    /// Send one request to the GUI owner and return its live-state reply.
    static func deliver(
        _ op: CommandIPC.Operation,
        rule: MapLocalRule? = nil,
        target: Selector? = nil,
        by: Int? = nil,
        tool: String? = nil,
        enabled: Bool? = nil,
        list: String? = nil,
        pattern: String? = nil,
        add: Bool? = nil,
        archivePath: String? = nil,
        bundleName: String? = nil,
        ruleIDs: [UUID]? = nil
    ) async throws -> CommandIPC.Result? {
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
            add: add,
            archivePath: archivePath,
            bundleName: bundleName,
            ruleIDs: ruleIDs
        )
        guard let result = CommandIPC.request(message, timeout: 8) else {
            throw CLIError("the GUI app owns the proxy but did not respond within 8s — is it still open? (check: proxymaxx-cli status)")
        }
        guard result.ok else {
            throw CLIError(result.error ?? "command rejected by the GUI app")
        }
        return result
    }

    // MARK: - list

    /// NDJSON rule objects by default; `--text` gives a human one-line-per-rule summary.
    private static func list(_ arguments: Arguments) async throws {
        let file = try await mapLocalSnapshot(arguments)
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

        if appOwned(for: arguments) {
            let result = try await deliver(.add, rule: rule)
            try emitRule(result?.rule ?? rule)
            return
        }

        var file = try loadRulesFile(rulesFile)
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

    // MARK: - import-har

    /// `rule import-har <file.har> [--include-non-success] [--dry-run]` — the CLI
    /// counterpart of the app's Import HAR button: every HAR entry with a response
    /// body becomes one Map Local rule whose destination is a full HTTP/1.1 response
    /// file written into the app's map-local directory, using the same `HARImporter`
    /// the GUI drives. Response files are shared by absolute path, so rules created
    /// here serve identically whether the app engine or `serve` owns the proxy.
    private static func importHar(_ arguments: Arguments) async throws {
        guard arguments.positional.count == 1 else {
            throw CLIError("rule import-har needs exactly one positional HAR file path", hint: "e.g. proxymaxx-cli rule import-har ~/capture.har")
        }
        let harURL = URL(fileURLWithPath: (arguments.positional[0] as NSString).expandingTildeInPath).standardizedFileURL
        guard FileManager.default.fileExists(atPath: harURL.path) else {
            throw CLIError("no HAR file at \(harURL.path)")
        }
        let data: Data
        do {
            data = try Data(contentsOf: harURL)
        } catch {
            throw CLIError("cannot read HAR file at \(harURL.path): \(error.localizedDescription)")
        }
        let entries: [HAREntry]
        do {
            entries = try HARImporter.parse(data)
        } catch {
            throw CLIError("invalid HAR file at \(harURL.path): \(error.localizedDescription)")
        }

        // Mirror the GUI import: entries without a body are skipped, and by default
        // so are responses outside 2xx. makeRule doubles as the final URL check,
        // which is what the GUI's preview loop skips on.
        let includeNonSuccess = arguments.has("include-non-success")
        struct Importable {
            let entry: HAREntry
            let rule: MapLocalRule
            let fileURL: URL
        }
        var importable: [Importable] = []
        var skipped = 0
        for entry in entries {
            guard HARImporter.hasBody(entry) else { skipped += 1; continue }
            let status = entry.response?.status ?? 0
            if !includeNonSuccess, !(200..<300).contains(status) { skipped += 1; continue }
            let fileURL = HARImporter.responseFileURL(for: entry, in: MapLocalResponseTemplate.directory)
            guard let rule = HARImporter.makeRule(for: entry, responseFileURL: fileURL) else { skipped += 1; continue }
            importable.append(Importable(entry: entry, rule: rule, fileURL: fileURL))
        }

        if arguments.has("dry-run") {
            for item in importable {
                // No destination file name here: the real import names files with a
                // fresh UUID segment, so the preview's name would never match.
                let preview: [String: Any] = [
                    "bytes": HARImporter.bodyData(for: item.entry.response?.content)?.count ?? 0,
                    "method": item.rule.method.displayName,
                    "status": item.entry.response?.status ?? 0,
                    "url": item.rule.url,
                ]
                let data = try JSONSerialization.data(withJSONObject: preview, options: [.sortedKeys])
                FileHandle.standardOutput.write(data)
                FileHandle.standardOutput.write(Data("\n".utf8))
            }
            note("would import \(importable.count) rule(s) from \(harURL.path)")
            return
        }

        guard !importable.isEmpty else {
            if !includeNonSuccess {
                throw CLIError("no importable entries in \(harURL.path)", hint: "add --include-non-success to import responses outside 2xx too")
            }
            throw CLIError("no importable entries in \(harURL.path) — entries need a response with a body")
        }

        // Response files first, so a write failure never leaves a rule pointing
        // at a missing file. `responseFileURL` names carry a fresh UUID segment,
        // so an existing-file refusal here is effectively unreachable.
        for item in importable {
            do {
                try HARImporter.writeResponse(for: item.entry, to: item.fileURL)
            } catch {
                throw CLIError(error.localizedDescription)
            }
        }

        if appOwned(for: arguments) {
            for item in importable {
                let result = try await deliver(.add, rule: item.rule)
                try emitRule(result?.rule ?? item.rule)
            }
        } else {
            let rulesFile = resolveRulesFile(arguments)
            var file = try loadRulesFile(rulesFile)
            for item in importable {
                file.mapLocalRules.append(item.rule)
            }
            try file.write(to: rulesFile)
            for item in importable {
                try emitRule(item.rule)
            }
        }

        var summary = "imported \(importable.count) rule(s) from \(harURL.path)"
        if skipped > 0 { summary += " (skipped \(skipped))" }
        note(summary)
    }

    // MARK: - template

    /// `rule template [--out PATH] [--force] [--print]` — write the starter response the
    /// app's **Insert Default Template** button inserts, so an agent can create a valid
    /// override without inventing HTTP framing.
    ///
    /// No `--out` chooses a fresh `default_message_<8>.json` under the app's map-local
    /// directory, exactly like the editor. The destination path is printed as one JSON
    /// object on stdout, ready to feed into `rule add --file`.
    private static func template(_ arguments: Arguments) throws {
        let out = arguments.value("out")
        if arguments.has("print") || out == "-" {
            guard out == nil || out == "-" else {
                throw CLIError("--print writes no file, so --out must be omitted or '-'")
            }
            FileHandle.standardOutput.write(MapLocalResponseTemplate.data)
            return
        }

        let destination: URL?
        if let out {
            guard !out.trimmingCharacters(in: .whitespaces).isEmpty else {
                throw CLIError("--out needs a path, or - for standard output")
            }
            destination = URL(fileURLWithPath: (out as NSString).expandingTildeInPath).standardizedFileURL
        } else {
            destination = nil
        }

        let written: URL
        do {
            written = try MapLocalResponseTemplate.write(to: destination, overwrite: arguments.has("force"))
        } catch {
            throw CLIError(error.localizedDescription)
        }

        let metadata: [String: Any] = [
            "bytes": MapLocalResponseTemplate.data.count,
            "path": written.path,
            "template": "http-response",
        ]
        let data = try JSONSerialization.data(withJSONObject: metadata, options: [.sortedKeys])
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
        note("wrote default HTTP response template to \(written.path)")
    }

    // MARK: - remove / enable / disable / move / clear

    private static func remove(_ arguments: Arguments) async throws {
        guard let target = target(from: arguments) else {
            throw CLIError("rule remove needs --id, --name or --url", hint: "run `proxymaxx-cli rule list` to find one")
        }
        if appOwned(for: arguments) {
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
            pruneBundleMembership(in: &file)
            note("removed \(matched.count) rule\(matched.count == 1 ? "" : "s")")
        }
    }

    private static func setEnabled(_ arguments: Arguments, enabled: Bool) async throws {
        guard let target = target(from: arguments) else {
            throw CLIError("\(enabled ? "enabling" : "disabling") a rule needs --id, --name or --url", hint: "run `proxymaxx-cli rule list` to find one")
        }
        if appOwned(for: arguments) {
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
        if appOwned(for: arguments) {
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
        if appOwned(for: arguments) {
            _ = try await deliver(.clear)
            return
        }
        let rulesFile = resolveRulesFile(arguments)
        var file = try loadRulesFile(rulesFile)
        let count = file.mapLocalRules.count
        guard count > 0 else {
            note("nothing to clear — no map local rules in \(rulesFile.path)")
            return
        }
        file.mapLocalRules.removeAll()
        pruneBundleMembership(in: &file)
        try file.write(to: rulesFile)
        note("cleared \(count) rule\(count == 1 ? "" : "s")")
    }

    // MARK: - helpers

    /// Read, mutate and rewrite the rule file, preserving switches and policy untouched.
    static func mutate(_ rulesFile: URL, _ change: (inout RuleFile) async throws -> Void) async throws {
        var file = try loadRulesFile(rulesFile)
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
