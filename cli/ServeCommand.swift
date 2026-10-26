import Foundation
import ProxyKit
import FlowKit
import RuleKit
import CertKit
import SystemKit
import ClientKit

enum ServeCommand {
    /// Events the CLI main loop reacts to: the proxy's own event, or a stop signal.
    enum CLIEvent: Sendable {
        case proxy(ProxyEvent)
        case interrupted
    }

    static func run(_ arguments: Arguments) async throws {
        // Detect the GUI app or another serve before binding anything, mirroring
        // ProxyMaxx's model where the CLI attaches to an engine rather than running
        // its own. A live registry entry (pid liveness included) is decisive; the
        // successful-bind path below catches engines whose writer left no record.
        if let owner = ProxyRegistry.read() {
            note("proxy already running: owner=\(owner.owner.rawValue) pid=\(owner.pid) http=\(owner.httpPort)\(owner.socksPort.map { " socks=\($0)" } ?? "")")
            note("attach instead: `proxymaxx-cli rule …` applies live; `proxymaxx-cli status` shows owner; point clients at 127.0.0.1:\(owner.httpPort)")
            exit(ExitCode.proxyAlreadyRunning)
        }
        // `--detach` hands the run to a background copy of this same command and returns,
        // so an agent gets fire-and-forget without a second verb that starts the engine.
        // The child is marked in its environment, which is how it avoids re-detaching.
        if arguments.has("detach"), ProcessInfo.processInfo.environment["PROXYMAXX_DETACHED"] == nil {
            try DetachedServe.launch()
            return
        }
        let port = arguments.value("port").flatMap(Int.init) ?? 9090
        guard (1...65535).contains(port) else {
            throw CLIError("--port must be 1–65535")
        }
        let socksPort = arguments.value("socks-port").flatMap(Int.init)
        if let socksPort, !(1...65535).contains(socksPort) {
            throw CLIError("--socks-port must be 1–65535")
        }
        let flowMode = arguments.value("flow-mode") ?? "summary"
        guard flowMode == "summary" || flowMode == "full" else {
            throw CLIError("--flow-mode must be summary or full")
        }
        let rulesFile = RuleCommand.resolveRulesFile(arguments)

        // Rule file and rules this proxy serves. Defaults stand in for a missing file,
        // which is what the app does on a first run too.
        let ruleFile = RuleFile.load(from: rulesFile)
        if !FileManager.default.fileExists(atPath: rulesFile.path) {
            note("no rule file at \(rulesFile.path) yet — Map Local stays empty until something is added")
        }

        let authority = try CertificateStorage.loadOrCreate()
        let isTrusted = CertificateTrust.isInstalled(commonName: authority.commonName)
        if isTrusted {
            note("root CA trusted (\(authority.commonName)) — HTTPS can be decrypted")
        } else {
            note("warning: root CA is NOT trusted; HTTPS flows will fail. Run: proxymaxx-cli cert install")
        }

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: port, socksPort: socksPort),
            authority: authority
        )
        engine.clientResolver = ClientAppResolver()
        apply(ruleFile, to: engine)

        // The protocol with the rest of the program: funnel proxy callbacks (arbitrary
        // threads) and terminal signals into one ordered stream the main loop awaits.
        let events = AsyncStream<CLIEvent>(bufferingPolicy: .unbounded) { continuation in
            engine.onEvent = { continuation.yield(.proxy($0)) }
            installSignalHandlers { continuation.yield(.interrupted) }
        }

        // Publish captured flows for the other front-end (the GUI window attached to
        // this engine) and clear anything a previous run left behind before the first
        // snapshot lands.
        let spool = FlowSpool.Writer()
        spool.reset()

        // The durable, multi-reader session log. Unlike the spool it is never cleared by
        // a reader and survives this process, so `proxymaxx-cli flows` can read the session
        // long after the engine stops. A new run starts a fresh session.
        let sessionLog = SessionLog.Writer(url: sessionLogURL(arguments))
        sessionLog.reset()

        try engine.start()
        // The port the engine actually bound. `start()` rewrites `configuration.port` when
        // the OS hands back a different one, so the two agree here either way.
        let boundPort = engine.boundPort ?? engine.configuration.port
        // Publish this engine so the GUI app (and any later command) can see the owner.
        try ProxyRegistry.write(
            ProxyRegistryEntry(
                owner: .cli,
                pid: Int(ProcessInfo.processInfo.processIdentifier),
                httpPort: boundPort,
                socksPort: engine.boundSocksPort
            )
        )
        defer { ProxyRegistry.clear() }
        defer { spool.clear() }
        // The browser companion reads the proxy's port from the bridge file and nowhere
        // else, so a CLI-owned engine has to publish it too. With no app running, the
        // extension would otherwise keep pointing the browser at whatever port the last
        // app run left behind, and every request in that browser would fail. `running` in
        // the contract means an engine is listening — this app's or the CLI's — so it is
        // retired on the way out, never left claiming a listener that has gone.
        publishBrowserBridgeState(
            httpPort: boundPort,
            socksPort: engine.boundSocksPort,
            running: true,
            caTrusted: isTrusted
        )
        defer {
            publishBrowserBridgeState(
                httpPort: boundPort,
                socksPort: nil,
                running: false,
                caTrusted: isTrusted
            )
        }
        note("listening on 127.0.0.1:\(boundPort) [\(flowMode) flow lines]" + (socksPort == nil ? "" : ", socks \(engine.boundSocksPort ?? socksPort!)"))
        note("rules: \(engine.mapLocalRules.count) map local from \(rulesFile.path) (watching for changes)")
        note("session log: \(sessionLog.url.path) (read it with `proxymaxx-cli flows`)")
        note("set http_proxy/https_proxy (or a device) to 127.0.0.1:\(boundPort); SIGINT stops")

        // Keep the rule file fresh in the live engine so `proxymaxx-cli rule add` from a
        // second shell takes effect without restarting the proxy.
        let watcher = Task { @MainActor in
            var lastModified: Date?
            while !Task.isCancelled {
                if let stamp = modified(at: rulesFile), stamp != lastModified, lastModified != nil {
                    let fresh = RuleFile.load(from: rulesFile)
                    apply(fresh, to: engine)
                    note("rules reloaded: \(fresh.mapLocalRules.count) map local")
                }
                lastModified = modified(at: rulesFile)
                try? await Task.sleep(for: .milliseconds(400))
            }
        }
        defer { watcher.cancel() }

        var summaryCount = 0
        for await event in events {
            switch event {
            case .proxy(.flow(let flow)):
                FlowFormat.emit(flow, mode: flowMode)
                spool.write(flow)
                sessionLog.append(flow)
                summaryCount += 1
            case .proxy(.stateChanged(isRunning: false, port: _)):
                break
            case .proxy(.stateChanged(isRunning: true, port: _)):
                break
            case .proxy(.diagnostic):
                // The engine already writes these to stderr; nothing extra here.
                break
            case .interrupted:
                note("stopping on signal; \(summaryCount) flows streamed")
                engine.stop()
                break
            }
            if isShutdownEvent(event) { break }
        }
    }

    /// Push the whole rule file into the engine, honouring the master switches.
    private static func apply(_ file: RuleFile, to engine: ProxyEngine) {
        engine.sslProxyingPolicy = file.isSSLProxyingEnabled ? file.sslProxyingPolicy : SSLProxyingPolicy(include: [], exclude: [])
        engine.mapLocalRules = file.isMapLocalEnabled ? file.mapLocalRules : []
    }

    /// Publish the engine's state for the browser companion, mirroring
    /// `AppModel.publishBrowserBridgeState`.
    ///
    /// The native messaging host is stateless and answers from this file alone, so whoever
    /// owns the engine has to write it. This is the same contract the app honours; without
    /// it, a proxy running under `serve` leaves the extension pointed at the previous app
    /// run's port.
    private static func publishBrowserBridgeState(
        httpPort: Int,
        socksPort: Int?,
        running: Bool,
        caTrusted: Bool
    ) {
        BrowserBridge.publish(
            BrowserBridge.State(
                httpPort: httpPort,
                socksPort: socksPort,
                running: running,
                caTrusted: caTrusted,
                systemProxy: SystemProxy.isEnabled(host: "127.0.0.1", port: httpPort)
            )
        )
    }

    private static func modified(at url: URL) -> Date? {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
    }

    /// Signal sources must outlive `run()` — see `installSignalHandlers`.
    private static var signalSources: [DispatchSourceSignal] = []

    private static func installSignalHandlers(_ handler: @escaping @Sendable () -> Void) {
        signal(SIGINT, SIG_IGN)
        signal(SIGTERM, SIG_IGN)
        // Not the main queue, and retained for the process lifetime: a scope-local
        // DispatchSourceSignal is released immediately after resume(), so the handler
        // never fires and every signal is swallowed by the SIG_IGN above. The loop
        // itself calls `engine.stop()` on the yielded event, so this handler only has
        // to deliver the signal.
        for name in [SIGINT, SIGTERM] {
            let source = DispatchSource.makeSignalSource(signal: name, queue: .global())
            source.setEventHandler(handler: handler)
            source.resume()
            signalSources.append(source)
        }
    }

    /// Whether the received event means the main loop should exit. Diagnostics and flow
    /// lines continue; only a stop request or the proxy genuinely going down exits.
    private static func isShutdownEvent(_ event: CLIEvent) -> Bool {
        switch event {
        case .interrupted: return true
        case .proxy(.stateChanged(isRunning: false, _)): return true
        default: return false
        }
    }
}
