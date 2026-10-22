import Foundation
import RuleKit
import CertKit
import SystemKit

/// The tool-control half of the parity surface: system proxy, the "where do I point a
/// device" endpoint, the Map Local master switch, and session clearing. Each maps to a
/// command the shipped `proxymaxx-cli` has, and each acts on the same state the app does —
/// the live engine over `CommandIPC`, or the shared rule file.
enum ToolCommand {
    /// `proxymaxx-cli proxy on|off|status`
    static func proxy(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError("proxy needs an action (on|off|status)")
        }
        switch action {
        case "status":
            // `currentWebProxy` returns an optional tuple; `?? nil` flattens the double
            // optional that `try?` adds so `enabled` reads off a single check.
            let current = (try? SystemProxy.currentWebProxy()) ?? nil
            print(json([
                "enabled": current != nil,
                "host": current?.host ?? "127.0.0.1",
                "port": current?.port ?? activePort(),
            ]))
        case "on":
            try enableSystemProxy(arguments)
        case "off":
            try SystemProxy.disable()
            note("system proxy turned off on every network service")
        default:
            throw CLIError("proxy action must be on, off or status")
        }
    }

    /// `proxymaxx-cli proxy-host` — the address a device or script should use, as JSON.
    /// Matches the shipped command's `{"ip":…,"port":…}` shape so existing scripts keep
    /// working; falls back to loopback when there is no LAN address to hand out.
    static func proxyHost(_ arguments: Arguments) {
        let ip = AndroidToolchain.lanIPv4Address() ?? "127.0.0.1"
        print(json(["ip": ip, "port": activePort()]))
    }

    /// `proxymaxx-cli maplocal on|off` — the Map Local master switch, and the same command the
    /// shipped CLI exposes under this exact name.
    static func maplocal(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first, action == "on" || action == "off" else {
            throw CLIError("maplocal needs on or off")
        }
        try await RulesCommand.setToolSwitch(fileTool: "map-local", enabled: action == "on", arguments: arguments)
        note("map local \(action == "on" ? "enabled" : "disabled")")
    }

    /// `proxymaxx-cli clear-session` — empty the app's captured flows. Over IPC when the app
    /// owns the engine; a headless `serve` keeps no session, so there is nothing to clear.
    static func clearSession() async throws {
        guard RuleCommand.appOwned() else {
            note("nothing to clear: a headless `proxymaxx-cli serve` streams flows and keeps no session")
            return
        }
        _ = try await RuleCommand.deliver(.clearSession)
        note("session cleared in the app")
    }

    /// A tool the shipped CLI has but this build does not implement yet. Report it in the
    /// same shape as a real failure so an agent's error handling does not fork.
    static func unsupported(_ tool: String, reason: String) -> Never {
        RulesEnvelope.fail(tool: tool, action: "info", code: "unsupported", message: reason)
    }

    // MARK: - Helpers

    private static func enableSystemProxy(_ arguments: Arguments) throws {
        // The app refuses to route the machine through the proxy until the root CA is
        // trusted; doing it here too keeps the CLI from being the one way to break HTTPS.
        let authority = try CertificateStorage.loadOrCreate()
        guard CertificateTrust.isInstalled(commonName: authority.commonName) else {
            throw CLIError("the root CA is not trusted yet — run `proxymaxx-cli cert install` first", hint: "enabling the system proxy without it makes every HTTPS connection fail")
        }
        let port = arguments.value("port").flatMap(Int.init) ?? activePort()
        try SystemProxy.enable(host: "127.0.0.1", port: port)
        note("system proxy on for every network service → 127.0.0.1:\(port)")
    }

    /// The port a client should target: the running engine's, whichever owns it, else the
    /// default the app stores. Read from the registry so the CLI and the app agree.
    private static func activePort() -> Int {
        if let owner = ProxyRegistry.read() { return owner.httpPort }
        return 9090
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])) ?? Data()
        return String(decoding: data, as: UTF8.self)
    }
}
