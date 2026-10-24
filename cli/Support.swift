import Foundation
import Dispatch
import RuleKit

/// Shared argument-parsing helpers for the CLI. Hand-rolled on purpose: a debugging
/// proxy that pulls in a package manager's worth of argument libraries does not earn it.
struct Arguments {
    /// Raw tokens as passed on the command line (after the program name).
    let tokens: [String]
    /// Words that were not part of a `--flag value` pair.
    let positional: [String]
    /// Values for flags that take one, keyed without the leading dashes.
    let values: [String: String]

    init(_ arguments: [String]) {
        self.tokens = arguments
        var positional: [String] = []
        var values: [String: String] = [:]

        var index = 0
        while index < arguments.count {
            let token = arguments[index]
            guard let name = Self.optionName(token) else {
                positional.append(token)
                index += 1
                continue
            }
            if index + 1 < arguments.count, Self.optionName(arguments[index + 1]) == nil {
                values[name] = arguments[index + 1]
                index += 2
            } else {
                values[name] = ""
                index += 1
            }
        }
        self.positional = positional
        self.values = values
    }

    /// The option name behind a token, or nil when the token is a positional value.
    ///
    /// `--output` and `-o` both count, so a script written against the shipped
    /// `proxymaxx-cli` (`-o`, `-i`, `-m`) runs here unchanged. A leading dash followed by a
    /// digit stays positional, which is what keeps `--by -1` reading as a value.
    private static func optionName(_ token: String) -> String? {
        if token.hasPrefix("--"), token.count > 2 {
            return String(token.dropFirst(2))
        }
        if token.hasPrefix("-"), token.count > 1, let first = token.dropFirst().first, first.isLetter {
            return String(token.dropFirst())
        }
        return nil
    }

    /// Everything after `word` in the original token order — subcommand dispatch.
    func after(_ word: String) -> Arguments {
        guard let index = tokens.firstIndex(of: word) else {
            return Arguments([])
        }
        return Arguments(Array(tokens[(index + 1)...]))
    }

    func has(_ name: String) -> Bool { values[name] != nil }
    func value(_ name: String) -> String? { values[name] }
}

extension CommandLine {
    /// Everything after the program name.
    static var operandArguments: [String] {
        Array(arguments.dropFirst())
    }
}

/// Terminal help text, written for both humans and agents choosing a command.
enum Help {
    static let text = """
    proxymaxx-cli — headless companion CLI for the ProxyMaxx debugging proxy

    Usage:
      proxymaxx-cli serve   [--port N] [--socks-port N] [--rules PATH] [--flow-mode summary|full]
                           [--out PATH] [--detach]
                           Run the MITM proxy headless. Flow lines stream as NDJSON on
                           stdout; status notices go to stderr. Watches the rule file and
                           reloads Map Local rules into the live engine when it changes.
                           Refuses to start when a proxy (GUI app or serve) is running.
                           --detach starts the engine in the background and returns, so an
                           agent gets fire-and-forget; read the session afterwards with
                           `proxymaxx-cli flows`. --out names the session log (default under
                           Application Support/ProxyMaxx/session.ndjson).
      proxymaxx-cli stop   [--force]
                           Ask the process that owns the engine (CLI or app) to stop.
                           Idempotent: stopping when nothing runs still succeeds.
      proxymaxx-cli flows  [--filter TEXT] [--method M] [--errors-only] [--host H] [--app A]
                           [--pinned] [--saved] [--since 30s|5m|2h|1d] [--limit N]
                           [--flow-mode summary|full] [--out PATH] [--follow] [--text]
                           Print captured flows from the session log, narrowed exactly
                           like the app's filter bar. --follow tails new flows until
                           interrupted or the engine stops, printing each flow once from
                           its closing snapshot. One NDJSON object per line, the same
                           shape `serve` streams; --text prints one line per flow.
      proxymaxx-cli status                 Print owner/pid/ports of the running proxy.
      proxymaxx-cli proxy on | off | status   Manage the macOS system HTTP/HTTPS proxy.
      proxymaxx-cli proxy-host             Print local proxy IP and port as JSON for scripts.
      proxymaxx-cli maplocal on | off      Toggle the Map Local tool.
      proxymaxx-cli clear-session          Empty the app's captured flows (app must be open).

      proxymaxx-cli rules map-local list | get <id> | create <url> | update <id> | delete <id>
                                    | enable [<id>] | disable [<id>]
      proxymaxx-cli rules ssl-proxying list | create --list include|exclude --pattern P
                                    | delete --list include|exclude --pattern P
                                    | enable | disable
                           JSON rule surface mirroring the shipped `proxymaxx-cli`, with the
                           same envelope: {"api_version":1,"ok":…,"tool":…,"action":…,…}.
                           map-local create/update take --path [--kind file|directory]
                           [--delay-ms N] [--name N] [--method M] [--match wildcard|regex|
                           contains|exact] [--include-subpaths BOOL] [--enabled BOOL]
                           [--input PATH|-]; update also needs the rule id positionally.
                           Other tools answer with an `unsupported` envelope.

      proxymaxx-cli rule list      [--rules PATH] [--text]
      proxymaxx-cli rule add       --url PATTERN --file PATH [--method M] [--name NAME]
                                  [--style contains|wildcard|regex|exact] [--host-only]
                                  [--delay SECONDS]
      proxymaxx-cli rule remove    (--id UUID | --name NAME | --url PATTERN)
      proxymaxx-cli rule enable    (--id UUID | --name NAME | --url PATTERN)
      proxymaxx-cli rule disable   (--id UUID | --name NAME | --url PATTERN)
      proxymaxx-cli rule move      --id UUID --by (-1|1 ...)
      proxymaxx-cli rule clear

      proxymaxx-cli export --output PATH [--mode all|enabledRules]
      proxymaxx-cli import --input  PATH [--mode append|override]
      proxymaxx-cli cert status | cert install | cert uninstall | cert export --out PATH

      proxymaxx-cli android devices
      proxymaxx-cli android prepare [--serial S] [--mode auto|google-apis|manual]
                                   [--magisk|--no-magisk] [--include-physical]
                           One-click emulator setup from the shell: install the root CA as a
                           system certificate, point the device at the running proxy (or
                           its tunnel), and install and launch the tunnel app. Uses
                           `adb root` on Google APIs images; on a Google Play AVD the
                           bundled, consent-based Magisk route does the rooting. Needs a
                           running engine with a SOCKS5 listener when the tunnel APK is
                           bundled. --mode manual prints the exact installer command and
                           touches nothing.
      proxymaxx-cli android revert  [--serial S] [--magisk|--no-magisk]
                                    [--include-physical]
                           Clear the proxy, remove the certificate and tunnel app, and
                           return a Magisk-patched AVD to its stock boot.

      proxymaxx-cli paths

    All rule commands read and write the same JSON file the app uses, so settings made
    here and in the app stay in step. When the GUI app is currently serving, edits are
    delivered to the app over a request file instead of the file itself, so they apply
    live in the running engine; `serve` watches the rule file, so edits apply without a
    restart. Short options (-o, -i, -m) are accepted alongside the long ones.
    """
}

/// Exit codes the CLI uses, deliberately reserved to stable values an agent can branch on.
enum ExitCode {
    static let success: Int32 = 0
    static let failure: Int32 = 1
    static let usage: Int32 = 2
    /// `serve` found an engine it must not double-run: either the GUI app or another
    /// `proxymaxx-cli serve` is on the port. Agents can branch on it to switch to attach mode.
    static let proxyAlreadyRunning: Int32 = 3
}

/// Print one line to stderr so agents tailing the process see progress without it
/// polluting the NDJSON flow stream on stdout.
func note(_ message: String) {
    FileHandle.standardError.write(Data("[proxymaxx-cli] \(message)\n".utf8))
}

func fail(_ message: String, usage: Bool = false) -> Never {
    note("error: \(message)")
    if usage { print(Help.text) }
    exit(usage ? ExitCode.usage : ExitCode.failure)
}

/// The JSON envelope every `rules` command emits, matching the shape `proxymaxx-cli`
/// uses so an agent that already parses the shipped tool can parse this one:
///
///     {"api_version":1,"ok":true,"tool":"map-local","action":"list","data":{…}}
///
/// Errors carry `{"code","message"}` in place of `data`. Keys are sorted so two runs
/// with the same state are byte-identical.
enum RulesEnvelope {
    static func text(tool: String, action: String, data: Any? = nil, code: String? = nil, message: String? = nil) -> String {
        var object: [String: Any] = [
            "api_version": 1,
            "ok": code == nil,
            "tool": tool,
            "action": action,
        ]
        if let data { object["data"] = data }
        if let code { object["error"] = ["code": code, "message": message ?? code] }
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }

    /// Print a success envelope and return, so the caller continues normally.
    static func emit(tool: String, action: String, data: Any? = nil) {
        print(text(tool: tool, action: action, data: data))
    }

    /// Print an error envelope and exit non-zero: the command completed, it just failed.
    static func fail(tool: String, action: String, code: String, message: String) -> Never {
        print(text(tool: tool, action: action, code: code, message: message))
        exit(ExitCode.failure)
    }
}

/// Convert a `MapLocalRule` into the flat JSON object the `rules map-local` commands
/// read and write. Field names follow `proxymaxx-cli` where the concepts line up
/// (`enabled`, `method`, `url`, `match`, `include_subpaths`, `path`, `delay_ms`); `kind`
/// is ours alone, because a ProxyMaxx rule carries a file and a directory at once and
/// this build models `Map To` as one exclusive choice.
enum MapLocalJSON {
    static func object(_ rule: MapLocalRule) -> [String: Any] {
        [
            "id": rule.id.uuidString,
            "name": rule.name,
            "enabled": rule.isEnabled,
            "method": rule.method.displayName,
            "url": rule.url,
            "match": rule.matchStyle.rawValue,
            "include_subpaths": rule.includePath,
            "path": rule.destination.path,
            "kind": rule.destination.isFile ? "file" : "directory",
            "delay_ms": Int((rule.responseDelay * 1000).rounded()),
        ]
    }

    /// Apply the changed fields of a JSON object onto a rule. Unknown keys are ignored
    /// rather than fatal so a payload written for the shipped `proxymaxx-cli` still loads
    /// the fields both tools share.
    static func apply(_ object: [String: Any], to rule: inout MapLocalRule) throws {
        if let name = object["name"] as? String { rule.name = name }
        if let enabled = object["enabled"] as? Bool { rule.isEnabled = enabled }
        if let method = object["method"] as? String { rule.method = MethodMatch(method) }
        if let url = object["url"] as? String { rule.url = url }
        if let match = object["match"] as? String {
            guard let style = URLMatchStyle(rawValue: match) else {
                throw CLIError("match must be one of contains|wildcard|regex|exact")
            }
            rule.matchStyle = style
        }
        if let include = object["include_subpaths"] as? Bool { rule.includePath = include }
        if let delay = object["delay_ms"] as? Int { rule.responseDelay = Double(delay) / 1000 }
        if let path = object["path"] as? String {
            let kind = (object["kind"] as? String) ?? (rule.destination.isFile ? "file" : "directory")
            rule.destination = kind == "directory" ? .directory(expanded(path)) : .file(expanded(path))
        } else if let kind = object["kind"] as? String, !rule.destination.path.isEmpty {
            rule.destination = kind == "directory" ? .directory(rule.destination.path) : .file(rule.destination.path)
        }
    }

    static func expanded(_ path: String) -> String { (path as NSString).expandingTildeInPath }
}

/// Parse a `--flag` value as a boolean. A bare `--flag` (empty value) reads as true,
/// matching how the app treats an `--enabled` switch with no argument.
func boolValue(_ arguments: Arguments, _ name: String) throws -> Bool? {
    guard let raw = arguments.value(name) else { return nil }
    switch raw.lowercased() {
    case "", "true", "yes", "1", "on": return true
    case "false", "no", "0", "off": return false
    default: throw CLIError("--\(name) must be true or false, got '\(raw)'")
    }
}

/// Read a JSON object from a file path, or from stdin when the path is `-`.
func readJSONObject(at path: String) throws -> [String: Any] {
    let data: Data
    if path == "-" {
        data = FileHandle.standardInput.readDataToEndOfFile()
    } else {
        let expanded = (path as NSString).expandingTildeInPath
        guard let read = FileManager.default.contents(atPath: expanded) else {
            throw CLIError("no readable JSON at \(expanded)")
        }
        data = read
    }
    guard let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        throw CLIError("--input must contain a JSON object")
    }
    return object
}

/// Where a detached `serve` writes its diagnostics. Flows go to the session log, not
/// here; this file is only the stderr the background process would otherwise lose.
enum ServeLog {
    static var logURL: URL {
        ProxyRegistry.defaultDirectory.appendingPathComponent("serve.log")
    }
}

/// The session log a command should use: `--out PATH` when given, else the shared
/// default under Application Support. `serve` writes it, `flows` reads it.
func sessionLogURL(_ arguments: Arguments) -> URL {
    guard let out = arguments.value("out"), !out.isEmpty else {
        return SessionLog.defaultURL
    }
    return URL(fileURLWithPath: (out as NSString).expandingTildeInPath)
}

/// A one-way interrupt flag for long-running reads like `flows --follow`.
///
/// The Dispatch sources must be retained for the process lifetime — a scope-local one is
/// released right after `resume()` and never fires — so they live here and the owner
/// keeps this object alive for as long as it polls.
final class InterruptFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var flag = false
    private var sources: [DispatchSourceSignal] = []

    func install() {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        for name in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: name, queue: .global())
            source.setEventHandler { [weak self] in
                guard let self else { return }
                lock.lock(); flag = true; lock.unlock()
            }
            source.resume()
            sources.append(source)
        }
    }

    var isInterrupted: Bool {
        lock.lock(); defer { lock.unlock() }
        return flag
    }
}
