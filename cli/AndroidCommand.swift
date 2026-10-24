import Foundation
import CertKit
import RuleKit
import SystemKit

/// The app's one-click Android setup from a shell: certificate, interception and tunnel
/// in one installer run, with the same script and arguments as the emulator guide.
enum AndroidCommand {
    static func run(_ arguments: Arguments) async throws {
        guard let action = arguments.positional.first else {
            throw CLIError(
                "android needs an action (devices|prepare|revert)",
                hint: "proxymaxx-cli android devices, then `proxymaxx-cli android prepare`"
            )
        }
        let body = arguments.after(action)
        switch action {
        case "devices":
            try devices()
        case "prepare":
            try await prepare(body)
        case "revert":
            try await revert(body)
        default:
            throw CLIError("unknown android action '\(action)'", hint: "devices|prepare|revert")
        }
    }

    // MARK: - Actions

    /// `android devices`: what `prepare` can target, in the same JSON shape everywhere.
    private static func devices() throws {
        try requireADB()
        let listed = AndroidToolchain.devices().map { device -> [String: Any] in
            [
                "serial": device.serial,
                "model": device.model,
                "emulator": device.isEmulator,
                "host": AndroidToolchain.hostAddress(forEmulator: device.isEmulator),
            ]
        }
        print(json(["action": "devices", "ok": true, "devices": listed]))
    }

    /// `android prepare`: certificate, interception and tunnel in one run.
    private static func prepare(_ arguments: Arguments) async throws {
        let mode = try installMode(arguments)
        let paths = try installerPaths()
        let enableMagisk = try magiskConsent(arguments)
        let includePhysical = try boolValue(arguments, "include-physical") ?? false
        let authority = try CertificateStorage.loadOrCreate()
        let owner = ProxyRegistry.read()

        if mode == .manual {
            // Manual touches nothing, so it needs no engine or attached device: it prints
            // the guide's command. A named serial stays even when not attached yet.
            let device = manualDevice(arguments)
            let serial = arguments.value("serial").flatMap { $0.isEmpty ? nil : $0 } ?? device?.serial
            let isEmulator = device?.isEmulator ?? (serial?.hasPrefix("emulator-") ?? true)
            let request = AndroidInstallRequest(
                mode: .manual,
                host: AndroidToolchain.hostAddress(forEmulator: isEmulator),
                httpPort: owner?.httpPort ?? 9090,
                socksPort: owner?.socksPort ?? 8989,
                certificatePEM: authority.certificatePEM,
                includePhysical: includePhysical,
                enableMagisk: enableMagisk,
                serial: serial,
                stateDirectory: AndroidInstaller.stateDirectory()
            )
            print(json([
                "action": "manual",
                "ok": true,
                "serial": serial ?? NSNull(),
                "commandLine": AndroidInstaller.commandLine(for: request, paths: previewPaths(paths)),
            ]))
            return
        }

        let device = try selectDevice(arguments)
        try requirePhysicalConsent(device, includePhysical: includePhysical)

        // The tunnel and the device proxy both point at a live engine. Without one this
        // would install a certificate and a tunnel with nowhere to connect.
        guard let owner else {
            throw CLIError(
                "no proxy is running, so the emulator would have nothing to connect to",
                hint: "start one first: proxymaxx-cli serve --detach --socks-port 8989"
            )
        }
        // With the tunnel installed the script skips the device's HTTP proxy, so an
        // engine without SOCKS5 would leave the device unable to reach the proxy.
        if paths.tunnelAPK != nil, owner.socksPort == nil {
            throw CLIError(
                "the running proxy has no SOCKS5 listener for the tunnel to use",
                hint: "stop it and start again with one: proxymaxx-cli serve --detach --socks-port 8989"
            )
        }

        let request = AndroidInstallRequest(
            mode: mode,
            host: AndroidToolchain.hostAddress(forEmulator: device.isEmulator),
            httpPort: owner.httpPort,
            socksPort: owner.socksPort ?? 8989,
            certificatePEM: authority.certificatePEM,
            includePhysical: includePhysical,
            enableMagisk: enableMagisk,
            serial: device.serial,
            stateDirectory: AndroidInstaller.stateDirectory()
        )

        let usedMagisk = mode != .googleAPIs && enableMagisk && paths.magisk != nil
        let logURL = try await runInstaller(
            request,
            device: device,
            engineOwner: owner.owner,
            tunnel: paths.tunnelAPK != nil
        )
        // The script warns and continues when `adb install` fails (a stale copy with a
        // different signature is the usual cause), so its exit status is not the answer.
        if paths.tunnelAPK != nil, !logReportsTunnelInstalled(logURL) {
            throw CLIError(
                "the tunnel app did not install on \(device.displayName)",
                hint: "a copy with a different signature may be installed; run `adb -s \(device.serial) uninstall com.proxymaxx.vpn` and retry"
            )
        }
        print(json([
            "action": "prepare",
            "ok": true,
            "serial": device.serial,
            "emulator": device.isEmulator,
            "host": request.host,
            "httpPort": request.httpPort,
            "socksPort": request.socksPort,
            "mode": mode.rawValue,
            "engine": owner.owner.rawValue,
            "magisk": usedMagisk,
            "tunnel": paths.tunnelAPK != nil,
            "certificate": authority.commonName,
            "log": logURL.path,
        ]))
    }

    /// `android revert`: clear the proxy, remove the certificate and tunnel app, and
    /// return a Magisk-patched AVD to its stock boot. No engine is needed to undo.
    private static func revert(_ arguments: Arguments) async throws {
        let device = try selectDevice(arguments)
        let paths = try installerPaths()
        let enableMagisk = try magiskConsent(arguments)
        let includePhysical = try boolValue(arguments, "include-physical") ?? false
        let authority = try? CertificateStorage.loadOrCreate()
        let owner = ProxyRegistry.read()

        try requirePhysicalConsent(device, includePhysical: includePhysical)

        let request = AndroidInstallRequest(
            mode: .revert,
            host: AndroidToolchain.hostAddress(forEmulator: device.isEmulator),
            httpPort: owner?.httpPort ?? 9090,
            socksPort: owner?.socksPort ?? 8989,
            certificatePEM: authority?.certificatePEM,
            includePhysical: includePhysical,
            enableMagisk: enableMagisk,
            serial: device.serial,
            stateDirectory: AndroidInstaller.stateDirectory()
        )

        let logURL = try await runInstaller(
            request,
            device: device,
            engineOwner: owner?.owner,
            tunnel: paths.tunnelAPK != nil
        )
        print(json([
            "action": "revert",
            "ok": true,
            "serial": device.serial,
            "magisk": enableMagisk && paths.magisk != nil,
            "log": logURL.path,
        ]))
    }

    // MARK: - Installer

    /// Run the installer and stream its log to stderr while it works. The script can spend
    /// minutes patching and cold-booting an AVD, so silence until it exits would look hung.
    private static func runInstaller(
        _ request: AndroidInstallRequest,
        device: AndroidDevice,
        engineOwner: ProxyRegistryEntry.Owner?,
        tunnel: Bool
    ) async throws -> URL {
        let logURL = request.stateDirectory.appendingPathComponent("run.log")
        try FileManager.default.createDirectory(
            at: request.stateDirectory,
            withIntermediateDirectories: true
        )
        try? FileManager.default.removeItem(at: logURL)

        if request.mode == .revert {
            note("reverting \(device.displayName)")
        } else {
            var details = "\(request.host):\(request.httpPort), socks \(request.socksPort)"
            if let engineOwner { details += ", engine \(engineOwner.rawValue)" }
            details += tunnel ? ", tunnel installed" : ", HTTP proxy only (no tunnel APK)"
            note("preparing \(device.displayName): \(details)")
        }
        note("running the Android installer; its log streams below")

        let finished = CompletionFlag()
        let tail = Task.detached {
            var seen = 0
            while !finished.isSet {
                seen = printNewLog(at: logURL, from: seen)
                try? await Task.sleep(for: .milliseconds(300))
            }
            _ = printNewLog(at: logURL, from: seen)
        }

        do {
            _ = try await Task.detached { try AndroidInstaller.run(request, logURL: logURL) }.value
            finished.markDone()
            await tail.value
        } catch {
            finished.markDone()
            await tail.value
            throw CLIError(
                "\(error)",
                hint: "the installer log is at \(logURL.path)"
            )
        }

        note("\(request.mode == .revert ? "revert" : "prepare") finished (log \(logURL.path))")
        return logURL
    }

    /// Print only the log text this process has not printed yet, so the tail can resume.
    private static func printNewLog(at url: URL, from seen: Int) -> Int {
        guard let text = try? String(contentsOf: url, encoding: .utf8), text.count > seen else {
            return seen
        }
        for line in text.dropFirst(seen).split(separator: "\n", omittingEmptySubsequences: true) {
            note("android: \(line)")
        }
        return text.count
    }

    // MARK: - Arguments and resources

    private static func installMode(_ arguments: Arguments) throws -> AndroidInstallMode {
        switch (arguments.value("mode") ?? "auto").lowercased() {
        case "auto", "automatic":
            return .auto
        case "google-apis", "googleapis", "adb-root":
            return .googleAPIs
        case "manual":
            return .manual
        case "revert":
            throw CLIError(
                "--mode revert is the `android revert` action",
                hint: "proxymaxx-cli android revert"
            )
        default:
            throw CLIError("--mode must be auto, google-apis or manual")
        }
    }

    /// Magisk is on by default, matching the app's toggle, because that is what makes a
    /// Google Play AVD work; `--no-magisk` restricts the run to the `adb root` route.
    private static func magiskConsent(_ arguments: Arguments) throws -> Bool {
        if arguments.has("no-magisk") {
            guard !arguments.has("magisk") else {
                throw CLIError("--magisk and --no-magisk are mutually exclusive")
            }
            return false
        }
        return try boolValue(arguments, "magisk") ?? true
    }

    /// The manual preview's target: the named device when attached, else the preferred
    /// one. Nil is fine; the command then carries only the user's serial, or none.
    private static func manualDevice(_ arguments: Arguments) -> AndroidDevice? {
        guard AndroidToolchain.adbPath() != nil else { return nil }
        let connected = AndroidToolchain.devices()
        if let serial = arguments.value("serial"), !serial.isEmpty {
            return connected.first { $0.serial == serial }
        }
        return AndroidToolchain.preferredDevice(in: connected)
    }

    /// A real phone is a real change, so it takes the explicit flag even when `--serial`
    /// names it. The app's guide uses the same opt-in for attached devices.
    private static func requirePhysicalConsent(_ device: AndroidDevice, includePhysical: Bool) throws {
        guard device.isEmulator || includePhysical else {
            throw CLIError(
                "\(device.displayName) is a physical device",
                hint: "re-run with --include-physical to change it"
            )
        }
    }

    private static func requireADB() throws {
        guard AndroidToolchain.adbPath() != nil else {
            throw CLIError(
                "adb was not found",
                hint: "install Android SDK platform-tools and set ANDROID_SDK_ROOT (or ANDROID_HOME)"
            )
        }
    }

    /// The device to act on: `--serial`, else the first emulator, else the first device.
    /// The guide makes the same choice when it opens.
    private static func selectDevice(_ arguments: Arguments) throws -> AndroidDevice {
        try requireADB()
        let connected = AndroidToolchain.devices()

        if let serial = arguments.value("serial"), !serial.isEmpty {
            guard let device = connected.first(where: { $0.serial == serial }) else {
                let known = connected.map(\.serial).joined(separator: ", ")
                throw CLIError(
                    "no connected device with serial '\(serial)'",
                    hint: known.isEmpty ? "start an emulator or connect a device first" : "connected: \(known)"
                )
            }
            return device
        }
        guard let device = AndroidToolchain.preferredDevice(in: connected) else {
            throw CLIError(
                "no Android device or emulator is connected",
                hint: "start an AVD or plug in a device, then run `proxymaxx-cli android devices`"
            )
        }
        return device
    }

    /// Resolve the bundled script, tunnel APK and Magisk assets exactly as the app does.
    private static func installerPaths() throws -> AndroidInstallPaths {
        let script: URL
        do {
            script = try AndroidResources.installerScript()
        } catch {
            throw CLIError(
                "\(error)",
                hint: "rebuild with Scripts/bundle-app.sh, or point PROXYMAXX_RESOURCES at Resources/android"
            )
        }
        return AndroidInstallPaths(
            script: script,
            certificate: nil,
            tunnelAPK: AndroidResources.tunnelAPK(),
            magisk: AndroidResources.magiskAssets()
        )
    }

    /// The manual preview names the certificate file the installer will write, without
    /// writing it, so the printed command is the one an install would actually run.
    private static func previewPaths(_ paths: AndroidInstallPaths) -> AndroidInstallPaths {
        AndroidInstallPaths(
            script: paths.script,
            certificate: AndroidInstaller.stateDirectory().appendingPathComponent("proxymaxx-ca.pem"),
            tunnelAPK: paths.tunnelAPK,
            magisk: paths.magisk
        )
    }

    private static func json(_ object: [String: Any]) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]))
            ?? Data("{}".utf8)
        return String(decoding: data, as: UTF8.self)
    }
    /// The script prints this when `adb install` succeeded, and warns instead when it failed.
    private static func logReportsTunnelInstalled(_ url: URL) -> Bool {
        guard let text = try? String(contentsOf: url, encoding: .utf8) else { return false }
        return text.contains("Tunnel app installed")
    }
}

/// Set once the installer exits, so the log tail drains and stops polling.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func markDone() {
        lock.lock()
        value = true
        lock.unlock()
    }

    var isSet: Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}
