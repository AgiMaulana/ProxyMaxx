import Foundation
import ProxyKit
import RuleKit
import CertKit
import SystemKit

/// Command dispatch for the `proxymaxx-cli` front-end. Every command touches the same libraries the
/// GUI app does — ProxyKit engines, CertKit certificates, RuleKit rules — so behaviour is
/// identical whether you drive it from the window or from an agent shell.
@main
@MainActor
struct ProxyMaxxCLI {
    static func main() async {
        let arguments = Arguments(CommandLine.operandArguments)
        if arguments.has("h") || arguments.has("help") {
            print(Help.text)
            exit(ExitCode.success)
        }
        guard let command = arguments.positional.first else {
            print(Help.text)
            exit(ExitCode.usage)
        }

        do {
            switch command {
            case "serve":
                try await ServeCommand.run(arguments.after(command))
            case "stop":
                try StopCommand.run(arguments.after(command))
            case "flows":
                try await FlowsCommand.run(arguments.after(command))
            case "status":
                StatusCommand.printCurrent()
            case "rule":
                try await RuleCommand.run(arguments.after(command))
            case "rules":
                try await RulesCommand.run(arguments.after(command))
            case "cert":
                try await CertCommand.run(arguments.after(command))
            case "proxy":
                try await ToolCommand.proxy(arguments.after(command))
            case "proxy-host":
                ToolCommand.proxyHost(arguments.after(command))
            case "maplocal":
                try await ToolCommand.maplocal(arguments.after(command))
            case "clear-session":
                try await ToolCommand.clearSession()
            case "export":
                try TransferCommand.export(arguments.after(command))
            case "import":
                try TransferCommand.import(arguments.after(command))
            case "mcp":
                ToolCommand.unsupported("mcp", reason: "This build has no MCP server; drive the proxy with `proxymaxx-cli serve` and `proxymaxx-cli rules` instead.")
            case "activate", "unlink":
                ToolCommand.unsupported(command, reason: "ProxyMaxx has no licence key, so there is nothing to activate or unlink.")
            case "export-log":
                ToolCommand.unsupported("export-log", reason: "This build does not persist a session to export; `proxymaxx-cli serve` streams flows as NDJSON on stdout.")
            case "custom-cert":
                ToolCommand.unsupported("custom-cert", reason: "This build trusts its own generated root CA; use `proxymaxx-cli cert` to install, export or remove it.")
            case "map-remote", "scripting", "block-list", "allow-list", "reverse-proxy",
                 "network-condition", "no-caching", "dns-spoofing", "breakpoint":
                ToolCommand.unsupported(command, reason: "The \(command) tool is not implemented in this build yet.")
            case "paths":
                printPaths()
            default:
                fail("unknown command '\(command)'", usage: true)
            }
        } catch let error as CLIError {
            fail(error.message)
        } catch {
            fail("\(error)")
        }
    }

    private static func printPaths() {
        print("""
        rule file \(RuleCommand.defaultRulesFile.path)
        cert dir   \(CertificateStorage.defaultDirectory.path)
        ca pem     \(CertificateStorage.defaultDirectory.appendingPathComponent(CertificateStorage.certificateFileName).path)
        session    \(SessionLog.defaultURL.path)
        """)
    }
}

/// A user-facing CLI failure; thrown so every command reports in one uniform shape.
struct CLIError: Error {
    let message: String
    init(_ message: String) { self.message = message }

    init(_ message: String, hint: String) {
        self.message = "\(message) — hint: \(hint)"
    }
}
