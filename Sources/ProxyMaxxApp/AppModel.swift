import Foundation
import Darwin
import AppKit
import SwiftUI
import Combine
import FlowKit
import ProxyKit
import CertKit
import RuleKit
import SystemKit

/// Coordinates the proxy engine, the flow store, the rule store and the system-level
/// integrations. Everything the UI observes lives here.
@MainActor
final class AppModel: ObservableObject {
    @Published private(set) var isRunning = false
    @Published var port: Int = 9090 {
        didSet {
            guard port != oldValue else { return }
            UserDefaults.standard.set(port, forKey: Self.portDefaultsKey)
        }
    }
    /// Port for the SOCKS5 listener. Android devices reach the proxy through SOCKS5, since
    /// the system proxy never sees traffic from apps that ignore it.
    @Published var socksPort: Int = 8989 {
        didSet {
            guard socksPort != oldValue else { return }
            UserDefaults.standard.set(socksPort, forKey: Self.socksPortDefaultsKey)
        }
    }
    /// The port SOCKS5 actually bound, which differs if the requested one was already taken.
    @Published private(set) var boundSocksPort: Int?
    @Published private(set) var systemProxyEnabled = false
    @Published private(set) var certificateInstalled = false
    /// Set when a System Proxy request was refused for want of a trusted root certificate.
    /// The window turns this into a banner that names the cause and opens the Certificates
    /// pane, so the refusal leads somewhere instead of ending in an alert.
    @Published private(set) var trustCertificateRequired = false
    /// True when the system proxy still points here from a run that did not exit cleanly.
    @Published private(set) var staleSystemProxy = false
    /// Confirm certificate changes with Touch ID. Optional: no authorization is actually
    /// required for the user trust domain, so this is an extra confirmation, not a gate.
    @Published var useTouchIDForCertificates: Bool = false {
        didSet {
            guard useTouchIDForCertificates != oldValue else { return }
            UserDefaults.standard.set(useTouchIDForCertificates, forKey: Self.touchIDDefaultsKey)
        }
    }
    @Published var certificateCommonName: String = "ProxyMaxx Root CA"
    @Published var lastError: String?
    @Published var activityLog: [String] = []

    // MARK: - Android

    /// Which route the Android setup takes. See `AndroidInstallMode`.
    @Published var androidMode: AndroidInstallMode = .auto
    /// Whether to touch real devices as well as emulators. Off by default: the certificate
    /// install is destructive to the device's trust store.
    @Published var androidIncludePhysical = false
    @Published var androidSerial: String?
    @Published private(set) var androidDevices: [AndroidDevice] = []
    @Published private(set) var androidBusy = false
    @Published private(set) var androidLog: [String] = []
    /// The last Android setup failure. Shown inside the guide, not as an app alert: the
    /// guide is a sheet, so an alert attached to the main window would only appear after
    /// the sheet closes, which reads as the click having done nothing.
    @Published private(set) var androidError: String?
    /// Consent for the Play Store AVD route. Recorded explicitly because it is the one part
    /// of this feature that grants root on the emulator.
    @Published var androidEnableMagisk: Bool = true {
        didSet {
            guard androidEnableMagisk != oldValue else { return }
            UserDefaults.standard.set(androidEnableMagisk, forKey: Self.androidMagiskDefaultsKey)
        }
    }
    private var androidStreamTask: Task<Void, Never>?
    /// The two guide windows. Held here so the menu and the toolbar can both open them.
    @Published var showAndroidEmulatorGuide = false
    @Published var showAndroidDeviceGuide = false
    /// The Map Local window. Held here so both the menu and the toolbar can open it.
    @Published var showMapLocalWindow = false

    let flowStore = FlowStore()
    /// Point the store at `Application Support` so the rule lists survive a restart.
    let ruleStore = RuleStore(persistenceURL: RuleStore.defaultPersistenceURL)

    private var engine: ProxyEngine?
    private var authority: CertificateAuthority?
    /// Publishes snapshots for the other front-end while this app hosts the engine.
    private let flowSpool = FlowSpool.Writer()
    /// Durable, multi-reader session record, so `proxymaxx-cli flows` can read this app's
    /// capture too. Only written while this app owns the engine.
    private let sessionLog = SessionLog.Writer()

    /// Set while this app owns the system proxy, so it can be put back on exit.
    /// Read from the AppKit termination handler, which is not actor-isolated.
    private nonisolated(unsafe) var systemProxyEnabledByApp = false
    private static let portDefaultsKey = "ProxyMaxxPort"
    private static let socksPortDefaultsKey = "ProxyMaxxSocksPort"
    private static let touchIDDefaultsKey = "ProxyMaxxUseTouchID"
    private static let androidMagiskDefaultsKey = "AndroidEmulatorMagisk"

    init() {
        let stored = UserDefaults.standard.integer(forKey: Self.portDefaultsKey)
        if (1...65535).contains(stored) {
            port = stored
        }
        let storedSocks = UserDefaults.standard.integer(forKey: Self.socksPortDefaultsKey)
        if (1...65535).contains(storedSocks) {
            socksPort = storedSocks
        }
        if let storedMagisk = UserDefaults.standard.object(forKey: Self.androidMagiskDefaultsKey) as? Bool {
            androidEnableMagisk = storedMagisk
        }
        if let storedTouchID = UserDefaults.standard.object(forKey: Self.touchIDDefaultsKey) as? Bool {
            useTouchIDForCertificates = storedTouchID
        } else {
            useTouchIDForCertificates = BiometricGate.isAvailable
        }
    }

    // MARK: - Command line

    /// Honour `--autostart` and `--port <n>` so the app can be launched and driven from a script.
    func applyCommandLineOptions() {
        let arguments = CommandLine.arguments
        if let index = arguments.firstIndex(of: "--port"),
           index + 1 < arguments.count,
           let value = Int(arguments[index + 1]) {
            port = value
        }
        if arguments.contains("--autostart") {
            start()
        }
        if arguments.contains("--install-certificate") {
            if !isRunning { start() }
            installCertificateFromCommandLine()
        }
        if arguments.contains("--uninstall-certificate") {
            if !isRunning { start() }
            uninstallCertificateFromCommandLine()
        }
        if arguments.contains("--android-install") || arguments.contains("--android-revert") {
            if let index = arguments.firstIndex(of: "--android-serial"), index + 1 < arguments.count {
                androidSerial = arguments[index + 1]
            }
            if arguments.contains("--android-no-magisk") {
                androidEnableMagisk = false
            }
            if !isRunning { start() }
            androidRunFromCommandLine(mode: arguments.contains("--android-revert") ? .revert : .auto)
        }
    }

    /// Remove trust non-interactively, for the same scripting reason as the install path.
    private func uninstallCertificateFromCommandLine() {
        guard let der = authority?.certificateDER else {
            lastError = "no certificate authority available"
            return
        }
        let commonName = certificateCommonName
        func report(_ text: String) {
            FileHandle.standardError.write(Data("[cli] \(text)\n".utf8))
            log(text)
        }
        switch Self.runPrivileged({ try CertificateTrust.uninstall(certificateDER: der, commonName: commonName) }) {
        case .success:
            certificateInstalled = CertificateTrust.isInstalled(commonName: commonName)
            report("certificate uninstall done; still trusted=\(certificateInstalled)")
        case .cancelled:
            report("certificate uninstall cancelled")
        case .failure(let message):
            report("certificate uninstall failed: \(message)")
        }
    }

    /// Run the certificate install synchronously, without the interactive gate, so the
    /// flow can be exercised from a script.
    private func installCertificateFromCommandLine() {
        // Report directly on stderr as well: in command-line mode there is no window to
        // read the activity log from.
        func report(_ text: String) {
            FileHandle.standardError.write(Data("[cli] \(text)\n".utf8))
            log(text)
        }

        guard let der = authority?.certificateDER else {
            lastError = "no certificate authority available"
            report("certificate install aborted: no certificate authority (is the proxy running?)")
            return
        }
        let commonName = certificateCommonName

        let started = Date()
        switch Self.installCertificateWithPrivileges(der: der, commonName: commonName, requireBiometrics: false) {
        case .success:
            certificateInstalled = CertificateTrust.isInstalled(commonName: commonName)
            report("certificate install succeeded in \(String(format: "%.1f", Date().timeIntervalSince(started)))s; trusted=\(certificateInstalled)")
        case .cancelled:
            report("certificate install cancelled after \(String(format: "%.1f", Date().timeIntervalSince(started)))s")
        case .failure(let message):
            lastError = message
            report("certificate install failed after \(String(format: "%.1f", Date().timeIntervalSince(started)))s: \(message)")
        }
    }

    // MARK: - Proxy lifecycle

    func start() {
        guard !isRunning else { return }
        // One engine, one owner. When another piece of the tool already serves — the
        // ProxyMaxx CLI most often — adopt that engine instead of racing it for the port.
        // ProxyMaxx's own CLI↔app contract is the same shape: the second process attaches,
        // it does not bind. Without this the app reports "port in use" while a healthy
        // proxy is right there on that port.
        if let owner = ProxyRegistry.read() {
            externalOwner = owner
            lastError = nil
            log("The proxy is served by the \(owner.owner == .cli ? "ProxyMaxx CLI" : "app") on 127.0.0.1:\(owner.httpPort) (pid \(owner.pid)); attaching instead of starting a second engine.")
            syncAttachMode()
            return
        }
        guard (1...65535).contains(port) else {
            lastError = L10n.format("error.invalidPort", port)
            return
        }
        if Self.isPortInUse(port) {
            lastError = L10n.format("error.portInUse", port)
            return
        }
        do {
            let authority = try CertificateStorage.loadOrCreate()
            self.authority = authority
            self.certificateCommonName = authority.commonName
            self.certificateInstalled = CertificateTrust.isInstalled(commonName: authority.commonName)
            // The certificate now exists, so a previous "start the proxy first" notice in
            // the Android guide no longer describes the current state.
            self.androidError = nil

            let engine = try ProxyEngine(
                configuration: ProxyConfiguration(host: "127.0.0.1", port: port, socksPort: socksPort),
                authority: authority
            )
            engine.sslProxyingPolicy = ruleStore.effectivePolicy
            engine.mapLocalRules = ruleStore.effectiveMapLocalRules
            engine.onEvent = { [weak self] event in
                Task { @MainActor in self?.handle(event) }
            }
            // Fresh hand-off buffer before the first snapshot, so a reader never replays
            // a previous run's flows as if they were just captured.
            flowSpool.reset()
            sessionLog.reset()
            try engine.start()
            self.engine = engine
            self.port = engine.boundPort ?? port
            self.boundSocksPort = engine.boundSocksPort
            self.isRunning = true
            self.externalOwner = nil
            self.flowStore.setCapturing(true)
            self.publishOwnershipAndBeginConsuming(engine: engine)
            self.syncAttachMode()
            self.log("Proxy listening on 127.0.0.1:\(self.port)")
            if let boundSocksPort = engine.boundSocksPort {
                let moved = boundSocksPort == socksPort ? "" : " (port \(socksPort) was taken)"
                self.log("SOCKS5 listening on 127.0.0.1:\(boundSocksPort)\(moved)")
            }
        } catch {
            self.lastError = "\(error)"
            self.log("Failed to start: \(error)")
        }
    }

    func stop() {
        engine?.stop()
        engine = nil
        isRunning = false
        boundSocksPort = nil
        flowStore.setCapturing(false)
        flowSpool.clear()
        retractOwnership()
        if systemProxyEnabled {
            setSystemProxy(false)
        }
        syncAttachMode()
        log("Proxy stopped")
    }

    func clearSession() {
        flowStore.clear()
    }

    /// Push the current rule sets into the running engine.
    func applyRules() {
        engine?.sslProxyingPolicy = ruleStore.effectivePolicy
        engine?.mapLocalRules = ruleStore.effectiveMapLocalRules
    }

    // MARK: - System proxy

    func setSystemProxy(_ enabled: Bool) {
        if enabled, !certificateInstalled {
            systemProxyEnabled = false
            trustCertificateRequired = true
            log("System proxy not enabled: the root certificate is not trusted")
            return
        }
        trustCertificateRequired = false
        // Point the system at whichever engine is actually listening — ours, or the CLI
        // we attached to — so the toggle is honest in both modes.
        let port = activeProxyPort
        Task.detached {
            let outcome = Self.applySystemProxy(enabled: enabled, port: port)
            await MainActor.run {
                switch outcome {
                case .success:
                    self.systemProxyEnabled = enabled
                    self.systemProxyEnabledByApp = enabled
                    self.staleSystemProxy = false
                    self.log(enabled ? "System proxy enabled" : "System proxy disabled")
                    self.publishBrowserBridgeState()
                case .cancelled:
                    self.systemProxyEnabled = false
                    self.log("System proxy change cancelled")
                case .failure(let message):
                    self.systemProxyEnabled = false
                    self.lastError = message
                    self.log("System proxy change failed: \(message)")
                }
            }
        }
    }

    /// Apply the system proxy. `networksetup` needs no administrator rights, so this is
    /// silent; it escalates internally only if the OS refuses.
    nonisolated static func applySystemProxy(enabled: Bool, port: Int) -> PrivilegedOutcome {
        runPrivileged {
            if enabled {
                try SystemProxy.enable(host: "127.0.0.1", port: port)
            } else {
                try SystemProxy.disable()
            }
        }
    }

    func refreshSystemProxyState() {
        systemProxyEnabled = SystemProxy.isEnabled(host: "127.0.0.1", port: activeProxyPort)
    }

    // MARK: - Browser companion

    /// Manifests written by the last install, so the log can name the browsers reached.
    @Published private(set) var browserBridgeManifests: [String] = []

    /// Where the last install staged the extension, and the browsers it wrote host
    /// manifests for. The panel shows both: the browser loads the folder, and the
    /// manifests are what let the extension reach the app.
    @Published private(set) var browserExtensionPath: String?
    @Published private(set) var browserExtensionBrowsers: [String] = []

    /// The two companion panels. Held here so the menu can open them, and so a panel stays
    /// readable while the person switches to the browser or Finder.
    @Published var showBrowserExtensionPanel = false
    @Published var showCommandLinePanel = false

    /// The CLI that travels with the app. Resolved on demand because a bundled app and
    /// `swift run` keep it in different places, and a missing artifact should be named.
    var commandLineToolURL: URL { CLICompanion.binaryURL() }

    /// Publish proxy state for the browser extension's native messaging host to read.
    ///
    /// The host is stateless on purpose, so this file is the whole contract: the extension
    /// asks, the host answers from here. Cheap enough to write on every state change, and
    /// it is what turns "App not running" into a real port and CA verdict in the popup.
    func publishBrowserBridgeState() {
        BrowserBridge.publish(
            BrowserBridge.State(
                httpPort: activeProxyPort,
                socksPort: isRunning ? (boundSocksPort ?? socksPort) : nil,
                running: isRunning || isAttachedToExternalOwner,
                caTrusted: certificateInstalled,
                systemProxy: systemProxyEnabled
            )
        )
    }

    /// Install the native messaging host manifests and stage the extension, then open the
    /// panel that names the folder.
    ///
    /// Chromium refuses to let anything install an extension on the user's behalf, so
    /// "install" means exactly three things: write the manifests that authorise the
    /// extension's origin, copy the extension somewhere the browser can reach and Finder
    /// can show, and tell the user where it went. Claiming more than that would be a lie.
    func installBrowserExtension() {
        guard let hostBinary = BrowserBridge.resolveHostBinary() else {
            lastError = L10n.string("error.bridgeMissing")
            return
        }

        let written: [BrowserBridge.InstalledManifest]
        do {
            written = try BrowserBridge.installNativeMessagingHost(hostBinary: hostBinary)
        } catch {
            lastError = "\(error)"
            log("Browser bridge install failed: \(error)")
            return
        }
        browserBridgeManifests = written.map(\.manifest.path)
        browserExtensionBrowsers = written.map(\.browser)
        publishBrowserBridgeState()

        let extensionURL: URL
        do {
            extensionURL = try BrowserBridge.installExtension()
        } catch {
            lastError = "\(error)"
            log("Browser extension install failed: \(error)")
            return
        }

        browserExtensionPath = extensionURL.path
        log("Installed the browser extension at \(extensionURL.path).")
        showBrowserExtensionPanel = true
    }

    // MARK: - Privileged operations

    enum PrivilegedOutcome {
        case success
        case cancelled
        case failure(String)
    }

    nonisolated static func runPrivileged(_ operation: () throws -> Void) -> PrivilegedOutcome {
        do {
            try operation()
            return .success
        } catch ShellError.userCancelled {
            return .cancelled
        } catch {
            return .failure("\(error)")
        }
    }


    /// Put the system proxy back before the process exits.
    ///
    /// Called from the AppKit termination handler, so it must not hop actors; leaving the
    /// machine pointed at a dead port would break networking until it is repaired by hand.
    nonisolated func restoreSystemProxyBeforeExit() {
        guard systemProxyEnabledByApp else { return }
        systemProxyEnabledByApp = false
        // No privileges needed, so this is instant and silent even on Cmd+Q.
        try? SystemProxy.disable()
    }

    /// Notice a system proxy left behind by a previous run that did not shut down cleanly.
    func detectStaleSystemProxy() {
        guard !isRunning else {
            staleSystemProxy = false
            return
        }
        guard let current = try? SystemProxy.currentWebProxy() else {
            staleSystemProxy = false
            return
        }
        // Only flag the setting when nothing at all answers on it. In attach mode the CLI's
        // engine is a live listener, so a system proxy pointing there is not stale.
        let activePort = activeProxyPort
        staleSystemProxy = current.host == "127.0.0.1"
            && current.port == activePort
            && !Self.isPortInUse(activePort)
        if staleSystemProxy {
            log("System proxy still points at 127.0.0.1:\(activePort) with no listener — press Restore to repair it.")
        }
    }

    /// Clear a leftover system proxy setting.
    func restoreSystemProxy() {
        staleSystemProxy = false
        setSystemProxy(false)
    }

    /// True when something is already accepting connections on `127.0.0.1:port`.
    static func isPortInUse(_ port: Int) -> Bool {
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = in_port_t(UInt16(truncatingIfNeeded: port).bigEndian)
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(descriptor, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
            }
        }
        return result == 0
    }

    // MARK: - Certificate

    func installCertificate() {
        guard let authority else {
            lastError = L10n.string("error.startForCA")
            return
        }
        let der = authority.certificateDER
        let commonName = authority.commonName
        let requireBiometrics = useTouchIDForCertificates
        Task.detached {
            let outcome = Self.installCertificateWithPrivileges(
                der: der,
                commonName: commonName,
                requireBiometrics: requireBiometrics
            )
            await MainActor.run {
                switch outcome {
                case .success:
                    self.certificateInstalled = true
                    self.trustCertificateRequired = false
                    self.log("Root certificate installed and trusted")
                    self.publishBrowserBridgeState()
                case .cancelled:
                    self.log("Certificate installation cancelled")
                case .failure(let message):
                    self.certificateInstalled = false
                    self.lastError = message
                    self.log("Certificate installation failed: \(message)")
                }
            }
        }
    }

    /// Trust the CA.
    ///
    /// On first use the helper installation and the trust change share one approval: the
    /// install script performs both, because macOS only allows a trust change from a
    /// process holding a GUI-session authorization. Afterwards the helper is tried first
    /// and a prompt is used only if it refuses (as it must for trust settings).
    nonisolated static func installCertificateWithPrivileges(
        der: Data,
        commonName: String,
        requireBiometrics: Bool = false
    ) -> PrivilegedOutcome {
        if requireBiometrics, !BiometricGate.authorize(reason: L10n.string("error.authoriseTrust")) {
            return .cancelled
        }
        return runPrivileged { try CertificateTrust.install(certificateDER: der, commonName: commonName) }
    }

    func uninstallCertificate() {
        let commonName = certificateCommonName
        guard let der = authority?.certificateDER else {
            lastError = L10n.string("error.startForCert")
            return
        }
        let requireBiometrics = useTouchIDForCertificates
        Task.detached {
            let outcome: PrivilegedOutcome
            if requireBiometrics,
               !BiometricGate.authorize(reason: L10n.string("error.authoriseRemove")) {
                outcome = .cancelled
            } else {
                outcome = Self.runPrivileged {
                    try CertificateTrust.uninstall(certificateDER: der, commonName: commonName)
                }
            }
            await MainActor.run {
                if case .success = outcome {
                    self.certificateInstalled = false
                    self.log("Root certificate removed")
                }
            }
        }
    }

    func exportCertificate(to url: URL) {
        guard let authority else { return }
        do {
            try CertificateStorage.exportPEM(authority, to: url)
            log("Exported certificate to \(url.path)")
        } catch {
            lastError = "\(error)"
        }
    }

    // MARK: - Android setup

    /// Re-read the connected devices. The guide refreshes this when it opens.
    func refreshAndroidDevices() {
        androidDevices = AndroidToolchain.devices()
        if let current = androidSerial, !androidDevices.contains(where: { $0.serial == current }) {
            androidSerial = nil
        }
        if androidSerial == nil {
            androidSerial = androidDevices.first(where: { $0.isEmulator })?.serial ?? androidDevices.first?.serial
        }
    }

    var androidSelectedDevice: AndroidDevice? {
        androidDevices.first { $0.serial == androidSerial }
    }

    /// The host address the selected device will use, for display in the guide.
    var androidHostAddress: String {
        AndroidToolchain.hostAddress(forEmulator: androidSelectedDevice?.isEmulator ?? true)
    }

    /// The exact command Manual mode shows. Nil when the resources are not bundled.
    func androidCommandPreview() -> String? {
        guard let script = try? AndroidResources.installerScript() else { return nil }
        let paths = AndroidInstallPaths(
            script: script,
            certificate: nil,
            tunnelAPK: AndroidResources.tunnelAPK(),
            magisk: AndroidResources.magiskAssets()
        )
        return AndroidInstaller.commandLine(for: androidRequest(mode: androidMode), paths: paths)
    }

    func androidRequest(mode: AndroidInstallMode) -> AndroidInstallRequest {
        // Revert has to name the installed certificate in order to remove it, so the authority is
        // loaded even when the proxy is not running.
        let certificatePEM = authority?.certificatePEM
            ?? (try? CertificateStorage.loadOrCreate())?.certificatePEM
        return AndroidInstallRequest(
            mode: mode,
            host: androidHostAddress,
            httpPort: port,
            socksPort: boundSocksPort ?? socksPort,
            certificatePEM: certificatePEM,
            includePhysical: androidIncludePhysical,
            enableMagisk: androidEnableMagisk,
            serial: androidSerial,
            stateDirectory: AndroidInstaller.stateDirectory()
        )
    }

    func installCertificateOnAndroid() { runAndroid(mode: androidMode) }
    func revertAndroidChanges() { runAndroid(mode: .revert) }

    private func runAndroid(mode: AndroidInstallMode) {
        guard !androidBusy else { return }

        if mode == .manual {
            guard let command = androidCommandPreview() else {
                androidError = "\(AndroidResourceError.resourcesMissing)"
                return
            }
            androidError = nil
            androidLog = [L10n.string("error.runInTerminal"), "", command]
            return
        }

        guard AndroidToolchain.adbPath() != nil else {
            androidError = L10n.string("error.adbMissing")
            return
        }
        guard let device = androidSelectedDevice else {
            androidError = L10n.string("error.noDevice")
            return
        }
        if mode != .revert, authority == nil {
            androidError = L10n.string("error.startForCertShort")
            return
        }
        androidError = nil

        let request = androidRequest(mode: mode)
        let logURL = request.stateDirectory.appendingPathComponent("run.log")
        try? FileManager.default.createDirectory(at: request.stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logURL)

        androidLog = []
        appendAndroidLog([
            mode == .revert
                ? L10n.format("error.revertingOn", device.displayName)
                : L10n.format("error.installingOn", device.displayName, request.host, request.httpPort, request.socksPort),
        ])
        if request.enableMagisk {
            appendAndroidLog([L10n.string("error.playAVDNotice")])
        }
        androidBusy = true
        beginStreamingAndroidLog(at: logURL)

        Task.detached {
            do {
                try AndroidInstaller.run(request, logURL: logURL)
                await MainActor.run {
                    self.androidBusy = false
                    self.androidError = nil
                    self.appendAndroidLog([L10n.string("error.finished")])
                    self.log(mode == .revert ? "Android changes reverted" : "Android setup finished")
                    self.refreshAndroidDevices()
                }
            } catch {
                await MainActor.run {
                    self.androidBusy = false
                    self.androidError = "\(error)"
                    self.appendAndroidLog([L10n.format("error.failed", "\(error)")])
                    self.refreshAndroidDevices()
                }
            }
        }
    }

    /// Tail the installer's log file so the guide fills in while the script is still working.
    private func beginStreamingAndroidLog(at url: URL) {
        androidStreamTask?.cancel()
        androidStreamTask = Task { @MainActor in
            var seen = 0
            while androidBusy {
                seen = consumeAndroidLog(at: url, from: seen)
                try? await Task.sleep(for: .milliseconds(400))
            }
            _ = consumeAndroidLog(at: url, from: seen)
        }
    }

    private func consumeAndroidLog(at url: URL, from seen: Int) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.count > seen else { return seen }
        appendAndroidLog(
            String(text.dropFirst(seen))
                .split(separator: "\n", omittingEmptySubsequences: true)
                .map(String.init)
        )
        return text.count
    }

    private func appendAndroidLog(_ lines: [String]) {
        let addition = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        guard !addition.isEmpty else { return }
        androidLog.append(contentsOf: addition)
        if androidLog.count > 800 {
            androidLog.removeFirst(androidLog.count - 800)
        }
    }

    /// Run one Android operation to completion and report on stderr, so the feature can be
    /// exercised from a script with no window involved.
    private func androidRunFromCommandLine(mode: AndroidInstallMode) {
        func report(_ text: String) {
            FileHandle.standardError.write(Data("[cli] \(text)\n".utf8))
            log(text)
        }

        refreshAndroidDevices()
        if androidSerial == nil {
            androidSerial = androidDevices.first?.serial
        }

        let request = androidRequest(mode: mode)
        let logURL = request.stateDirectory.appendingPathComponent("run.log")
        try? FileManager.default.createDirectory(at: request.stateDirectory, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: logURL)
        report("android mode=\(mode.rawValue) serial=\(androidSerial ?? "-") host=\(request.host) http=\(request.httpPort) socks=\(request.socksPort)")

        var failureMessage: String?
        do {
            try AndroidInstaller.run(request, logURL: logURL)
        } catch {
            failureMessage = "\(error)"
        }

        if let text = try? String(contentsOf: logURL, encoding: .utf8) {
            for line in text.split(separator: "\n") { report(String(line)) }
        }

        if let failureMessage = failureMessage {
            lastError = failureMessage
            report("android \(mode.rawValue) failed: \(failureMessage)")
        } else {
            report("android \(mode.rawValue) succeeded")
        }
    }

    // MARK: - Cross-tool ownership (GUI ↔ CLI)

    /// Release the ownership record and stop the watchers on quit, so a subsequent
    /// `proxymaxx-cli serve` or app launch is not told the port is still ours.
    func flushCrossToolStateBeforeExit() {
        retractOwnership()
        externalWatchTask?.cancel()
        externalWatchTask = nil
        stopFlowIngest()
        // Only the engine host writes snapshots; clear them so the next run does not
        // replay this session's flows.
        if isRunning {
            flowSpool.clear()
        }
    }

    /// Set when `proxymaxx-cli serve` currently owns the proxy, so the window can say so
    /// instead of pretending the engine is dead. Mirrors ProxyMaxx: one engine, one
    /// owner, other tools attach.
    @Published private(set) var externalOwner: ProxyRegistryEntry?

    /// True while another engine (the CLI) serves and this app has adopted it rather than
    /// binding its own. The window reports that engine's address, not "Not running".
    var isAttachedToExternalOwner: Bool { externalOwner != nil && !isRunning }

    /// The address a client should use right now — this app's port when its engine is up,
    /// otherwise the external engine's port, so the status line and the System Proxy
    /// toggle agree with whatever is actually listening.
    var activeProxyPort: Int { isRunning ? port : (externalOwner?.httpPort ?? port) }

    /// Adopt the owning engine once, without waiting for the poll, so the first frame
    /// after launch is correct.
    func refreshExternalOwner() {
        externalOwner = isRunning ? nil : ProxyRegistry.read()
        syncAttachMode()
    }

    /// Keep the window's read side in step with who owns the engine: while attached,
    /// stream the other front-end's flows in and report that capture is live; the
    /// moment this app hosts its own engine, stop reading the shared spool so its
    /// flows are not ingested twice.
    private func syncAttachMode() {
        if isAttachedToExternalOwner {
            flowStore.setCapturing(true)
            startFlowIngestIfAttached()
        } else {
            stopFlowIngest()
        }
        // Whoever owns the engine, the browser companion should hear about it.
        publishBrowserBridgeState()
    }

    private func startFlowIngestIfAttached() {
        guard flowIngestTask == nil else { return }
        flowIngestTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.ingestExternalFlows()
                try? await Task.sleep(for: .milliseconds(200))
            }
        }
    }

    private func stopFlowIngest() {
        flowIngestTask?.cancel()
        flowIngestTask = nil
    }

    /// Drain the shared spool into the visible session. Snapshots arrive oldest first;
    /// `upsert` replaces a flow in place by id, so the throttled interim snapshots and
    /// the final completed one collapse onto the same row.
    private func ingestExternalFlows() {
        for url in FlowSpool.pendingURLs() {
            if let flow = FlowSpool.read(url) {
                flowStore.upsert(flow)
            }
            FlowSpool.remove(url)
        }
    }

    /// Stop the CLI-owned engine and bind this app's own, the reverse of the attach path.
    /// The registry records the writer's pid, so this signals a process this tool started
    /// rather than blindly grabbing a busy port.
    func takeOverExternalProxy() {
        guard !isRunning else { return }
        guard let owner = externalOwner ?? ProxyRegistry.read(),
              owner.pid > 0,
              owner.pid != Int(ProcessInfo.processInfo.processIdentifier)
        else {
            start()
            return
        }
        let port = owner.httpPort
        kill(pid_t(owner.pid), SIGTERM)
        log("Asked the \(owner.owner == .cli ? "ProxyMaxx CLI" : "other app") (pid \(owner.pid)) to stop; taking over 127.0.0.1:\(port).")
        Task { @MainActor in
            // Give it up to ~5 s to release the port and the ownership record.
            for _ in 0..<50 {
                if ProxyRegistry.read() == nil && !Self.isPortInUse(port) { break }
                try? await Task.sleep(for: .milliseconds(100))
            }
            self.externalOwner = ProxyRegistry.read()
            if self.externalOwner == nil {
                self.start()
            } else {
                self.lastError = L10n.format("error.portHeld", port)
            }
        }
    }

    /// Set after this run publishes `owner = .app`, so exit paths only clear what they wrote.
    private var registryWritten = false
    private var externalWatchTask: Task<Void, Never>?
    private var commandConsumerTask: Task<Void, Never>?
    /// Reads the shared flow spool while the app is attached to a CLI-owned engine.
    private var flowIngestTask: Task<Void, Never>?

    /// Publish ownership right after the engine binds, and consume `proxymaxx-cli rule …`
    /// requests for as long as this engine serves.
    private func publishOwnershipAndBeginConsuming(engine: ProxyEngine) {
        do {
            try ProxyRegistry.write(
                ProxyRegistryEntry(
                    owner: .app,
                    pid: Int(ProcessInfo.processInfo.processIdentifier),
                    httpPort: engine.boundPort ?? port,
                    socksPort: engine.boundSocksPort
                )
            )
            registryWritten = true
        } catch {
            log("Could not record proxy ownership: \(error)")
        }
        guard commandConsumerTask == nil else { return }
        commandConsumerTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.consumeCommandRequests()
                try? await Task.sleep(for: .milliseconds(1200))
            }
        }
    }

    private func retractOwnership() {
        commandConsumerTask?.cancel()
        commandConsumerTask = nil
        guard registryWritten else { return }
        registryWritten = false
        ProxyRegistry.clear()
        log("Proxy ownership released")
    }

    /// Apply one CLI request against the live state, then answer the waiting CLI.
    /// Selectors mirror the CLI's: id, then name, then URL, all case-insensitive.
    private func consumeCommandRequests() {
        for (url, message) in CommandIPC.pendingMessages() {
            let result = applyCommandMessage(message)
            try? CommandIPC.respond(result)
            try? FileManager.default.removeItem(at: url)
            log("CLI command \(message.op.rawValue) → \(result.ok ? "ok" : "error: \(result.error ?? "")")")
        }
        applyRules()
    }

    private func applyCommandMessage(_ message: CommandIPC.Message) -> CommandIPC.Result {
        func fail(_ reason: String) -> CommandIPC.Result {
            CommandIPC.Result(id: message.id, ok: false, error: reason)
        }
        func matchingIndices() -> [Int] {
            ruleStore.mapLocalRules.indices.filter { index in
                let rule = ruleStore.mapLocalRules[index]
                if let targetID = message.targetID, let id = UUID(uuidString: targetID), rule.id == id { return true }
                if let name = message.targetName, rule.name.caseInsensitiveCompare(name) == .orderedSame { return true }
                if let url = message.targetURL, rule.url.caseInsensitiveCompare(url) == .orderedSame { return true }
                return false
            }
        }

        switch message.op {
        case .add:
            let rule = message.rule ?? MapLocalRule(url: "")
            guard !rule.url.isEmpty else { return fail("the request carried no rule") }
            ruleStore.addMapLocalRule(rule)
            return CommandIPC.Result(id: message.id, ok: true, rule: rule)
        case .update:
            guard let rule = message.rule, !rule.url.isEmpty else { return fail("the request carried no rule") }
            guard ruleStore.mapLocalRules.contains(where: { $0.id == rule.id }) else {
                return fail("no rule with id \(rule.id.uuidString)")
            }
            ruleStore.updateMapLocalRule(rule)
            return CommandIPC.Result(id: message.id, ok: true, rule: rule)
        case .remove:
            let ids = Set(matchingIndices().map { ruleStore.mapLocalRules[$0].id })
            guard !ids.isEmpty else { return fail("no rule matches the selector") }
            ruleStore.removeMapLocalRules(ids: ids)
            return CommandIPC.Result(id: message.id, ok: true)
        case .enable, .disable:
            let indices = matchingIndices()
            guard !indices.isEmpty else { return fail("no rule matches the selector") }
            let enabled = message.op == .enable
            for index in indices {
                var rule = ruleStore.mapLocalRules[index]
                rule.isEnabled = enabled
                ruleStore.updateMapLocalRule(rule)
            }
            return CommandIPC.Result(id: message.id, ok: true)
        case .move:
            guard let by = message.by, by != 0,
                  let targetID = message.targetID, let id = UUID(uuidString: targetID)
            else { return fail("move needs an id and a non-zero --by") }
            ruleStore.moveMapLocalRule(id: id, by: by)
            return CommandIPC.Result(id: message.id, ok: true)
        case .clear:
            ruleStore.clearMapLocalRules()
            return CommandIPC.Result(id: message.id, ok: true)
        case .setToolEnabled:
            guard let tool = message.tool, let enabled = message.enabled else {
                return fail("setToolEnabled needs a tool and an enabled flag")
            }
            switch tool {
            case "map-local":
                ruleStore.isMapLocalEnabled = enabled
            case "ssl-proxying":
                ruleStore.isSSLProxyingEnabled = enabled
            default:
                return fail("this build has no tool named '\(tool)'")
            }
            return CommandIPC.Result(id: message.id, ok: true)
        case .setSSLProxying:
            guard let list = message.list, let pattern = message.pattern, let add = message.add, !pattern.isEmpty else {
                return fail("setSSLProxying needs a list, a pattern and an add flag")
            }
            var policy = ruleStore.sslProxyingPolicy
            switch list {
            case "include":
                policy.include.removeAll { $0 == pattern }
                if add { policy.include.append(pattern) }
            case "exclude":
                policy.exclude.removeAll { $0 == pattern }
                if add { policy.exclude.append(pattern) }
            default:
                return fail("list must be include or exclude")
            }
            ruleStore.sslProxyingPolicy = policy
            return CommandIPC.Result(id: message.id, ok: true)
        case .clearSession:
            flowStore.clear()
            return CommandIPC.Result(id: message.id, ok: true)
        }
    }

    /// Poll the ownership file while this window is idle so the user sees CLI serve
    /// start and stop, the same way ProxyMaxx notices its own companion tools.
    func beginExternalOwnerWatch() {
        guard externalWatchTask == nil else { return }
        externalWatchTask = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                self?.refreshExternalOwner()
                try? await Task.sleep(for: .seconds(2))
            }
        }
    }

    // MARK: - Events

    private func handle(_ event: ProxyEvent) {
        switch event {
        case .flow(let flow):
            flowStore.upsert(flow)
            flowSpool.write(flow)
            sessionLog.append(flow)
        case .stateChanged(let running, let port):
            isRunning = running
            self.port = port
        case .diagnostic(let message):
            log(message)
        }
    }

    private func log(_ message: String) {
        let stamped = "[\(Self.timeFormatter.string(from: Date()))] \(message)"
        activityLog.append(stamped)
        if activityLog.count > 500 {
            activityLog.removeFirst(activityLog.count - 500)
        }
    }

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm:ss"
        return formatter
    }()
}
