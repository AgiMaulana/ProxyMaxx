import Foundation
import RuleKit

/// `proxymaxx-cli export` / `proxymaxx-cli import` — move the shared `RuleFile` in and out of a
/// file. This is the same document the app and the CLI already persist, so an export is
/// the whole debugging configuration and an import is a merge or a replace, mirroring the
/// shipped `proxymaxx-cli export|import` pair.
enum TransferCommand {
    static func export(_ arguments: Arguments) throws {
        guard let output = arguments.value("output") ?? arguments.value("o") else {
            throw CLIError("export needs --output PATH", hint: "proxymaxx-cli export --output ~/Desktop/proxymaxx-rules.json")
        }
        let mode = arguments.value("mode") ?? arguments.value("m") ?? "all"
        guard mode == "all" || mode == "enabledRules" else {
            throw CLIError("--mode must be all or enabledRules")
        }

        var file = RuleFile.load(from: RuleCommand.resolveRulesFile(arguments))
        if mode == "enabledRules" {
            file.mapLocalRules = file.mapLocalRules.filter { $0.isEnabled }
        }
        let url = URL(fileURLWithPath: (output as NSString).expandingTildeInPath)
        try file.write(to: url)
        note("exported \(file.mapLocalRules.count) map local rule\(file.mapLocalRules.count == 1 ? "" : "s") (\(mode)) to \(url.path)")
    }

    static func `import`(_ arguments: Arguments) throws {
        guard let input = arguments.value("input") ?? arguments.value("i") else {
            throw CLIError("import needs --input PATH", hint: "proxymaxx-cli import --input ~/Desktop/proxymaxx-rules.json")
        }
        let mode = arguments.value("mode") ?? arguments.value("m") ?? "append"
        guard mode == "append" || mode == "override" else {
            throw CLIError("--mode must be append or override")
        }

        let source = URL(fileURLWithPath: (input as NSString).expandingTildeInPath)
        guard FileManager.default.fileExists(atPath: source.path) else {
            throw CLIError("no config file at \(source.path)")
        }
        let incoming = RuleFile.load(from: source)
        let target = RuleCommand.resolveRulesFile(arguments)
        var file = RuleFile.load(from: target)

        switch mode {
        case "override":
            file = incoming
        default:
            // Append keeps the existing switches and policy and adds the incoming rules,
            // skipping any whose id is already present so a re-import cannot duplicate.
            let existing = Set(file.mapLocalRules.map(\.id))
            file.mapLocalRules.append(contentsOf: incoming.mapLocalRules.filter { !existing.contains($0.id) })
        }
        try file.write(to: target)
        note("imported \(incoming.mapLocalRules.count) map local rule\(incoming.mapLocalRules.count == 1 ? "" : "s") (\(mode)) into \(target.path)")
    }
}
