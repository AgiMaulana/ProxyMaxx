import Foundation
import Branding

/// The "Advanced Mode" choices offered by the Android install flow.
public enum AndroidInstallMode: String, CaseIterable, Sendable, Identifiable {
    /// Do whatever this machine needs: `adb root` when the image allows it, Magisk when it
    /// does not and the user has consented.
    case auto
    /// Force the Google APIs route. Refuses on a Play Store AVD instead of patching it,
    /// which is what someone who specifically wants a non-rooted-style setup picks.
    case googleAPIs
    /// Change nothing. Show the exact command for the user to run themselves.
    case manual
    /// Undo: clear the proxy, remove the tunnel app, and return a Magisk AVD to a stock boot.
    case revert

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .auto: return String(localized: "android.mode.automatic.title", defaultValue: "Automatic")
        case .googleAPIs: return String(localized: "android.mode.googleAPIs.title", defaultValue: "Google APIs (adb root)")
        case .manual: return String(localized: "android.mode.manual.title", defaultValue: "Manual command")
        case .revert: return String(localized: "android.mode.revert.title", defaultValue: "Revert all changes")
        }
    }

    public var explanation: String {
        switch self {
        case .auto:
            return String(localized: "android.mode.automatic.explanation", defaultValue: "Uses adb root on a Google APIs image. On a Google Play AVD, where adb root is unavailable, it offers the bundled Magisk route instead — but only with your consent.")
        case .googleAPIs:
            return String(localized: "android.mode.googleAPIs.explanation", defaultValue: "Only the adb root path. Nothing is patched, and an AVD whose adbd cannot be rooted is reported rather than modified.")
        case .manual:
            return String(localized: "android.mode.manual.explanation", defaultValue: "Neither the app nor your device is touched. The exact command is shown so you can run it in Terminal yourself.")
        case .revert:
            return String(localized: "android.mode.revert.explanation", defaultValue: "Clears the HTTP proxy, removes the tunnel app, and — if this app created a temporary Magisk session — restarts that AVD on its stock ramdisk.")
        }
    }

    var scriptMode: String {
        self == .revert ? "revertProxy" : "all"
    }
}

/// Everything the installer needs, resolved to real paths.
public struct AndroidInstallPaths: Sendable {
    public let script: URL
    public let certificate: URL?
    public let tunnelAPK: URL?
    public let magisk: AndroidMagiskAssets?

    public init(script: URL, certificate: URL?, tunnelAPK: URL?, magisk: AndroidMagiskAssets?) {
        self.script = script
        self.certificate = certificate
        self.tunnelAPK = tunnelAPK
        self.magisk = magisk
    }
}

/// One install or revert.
public struct AndroidInstallRequest: Sendable {
    public var mode: AndroidInstallMode
    public var host: String
    public var httpPort: Int
    public var socksPort: Int
    /// The CA in PEM form, which is what `openssl x509 -subject_hash_old` in the script needs.
    public var certificatePEM: String?
    public var includePhysical: Bool
    public var enableMagisk: Bool
    public var serial: String?
    public var stateDirectory: URL

    public init(
        mode: AndroidInstallMode,
        host: String,
        httpPort: Int,
        socksPort: Int,
        certificatePEM: String? = nil,
        includePhysical: Bool = false,
        enableMagisk: Bool = true,
        serial: String? = nil,
        stateDirectory: URL
    ) {
        self.mode = mode
        self.host = host
        self.httpPort = httpPort
        self.socksPort = socksPort
        self.certificatePEM = certificatePEM
        self.includePhysical = includePhysical
        self.enableMagisk = enableMagisk
        self.serial = serial
        self.stateDirectory = stateDirectory
    }
}

/// Builds and runs the Android installer.
///
/// The script is what does the work; this type only decides the arguments, writes the
/// certificate out, and runs the script as the current user. Root is obtained on the device,
/// through `adb root` or Magisk, so this Mac is never asked for administrator rights.
public enum AndroidInstaller {
    public enum Failure: Error, CustomStringConvertible {
        case certificateMissing
        case notRunnable(String)

        public var description: String {
            switch self {
            case .certificateMissing:
                return String(localized: "error.startForCertShort", defaultValue: "Start the proxy first, so the root certificate exists.")
            case .notRunnable(let detail):
                return detail
            }
        }
    }

    /// Where patch caches and logs live. Root-owned content is not written here; this is
    /// only the app's own record.
    public static func stateDirectory() -> URL {
        Brand.supportDirectory.appendingPathComponent("android", isDirectory: true)
    }

    /// The argument list handed to the script. Pure, so it can be asserted in tests.
    public static func arguments(for request: AndroidInstallRequest, paths: AndroidInstallPaths) -> [String] {
        var arguments = ["-m", request.mode.scriptMode]

        if request.mode != .revert {
            arguments += ["-i", request.host, "-p", String(request.httpPort)]
        }
        arguments += ["--socks-port", String(request.socksPort)]

        // Revert needs the certificate as well: the CA is installed into the device's user trust
        // store, so undoing the install means naming the file to remove.
        if let certificate = paths.certificate {
            arguments += ["-c", certificate.path]
        }

        if let serial = request.serial, !serial.isEmpty {
            arguments += ["--serial", serial]
        }
        if request.includePhysical {
            arguments.append("--include-physical")
        }

        if request.mode == .revert {
            arguments.append("--uninstall-vpn")
            // Only offered when the Magisk assets are actually present: a revert must not
            // promise to restore something this build cannot.
            if request.enableMagisk, paths.magisk != nil {
                arguments.append("--restore-magisk")
            }
        } else if let tunnelAPK = paths.tunnelAPK {
            arguments += ["--vpn-apk", tunnelAPK.path]
        }

        // The Google APIs mode is the explicit "do not patch my emulator" choice, so the
        // Magisk flags are withheld from it even when the assets exist.
        if request.mode != .revert, request.mode != .googleAPIs,
           request.enableMagisk, let magisk = paths.magisk {
            arguments += [
                "--enable-magisk",
                "--magisk-script", magisk.script.path,
                "--magisk-apk", magisk.apk.path,
                "--magisk-host-patch", magisk.hostPatch.path,
                "--magisk-state-dir", request.stateDirectory.appendingPathComponent("magisk").path,
            ]
        }

        return arguments
    }

    /// The same thing as something a person can paste into Terminal.
    public static func commandLine(for request: AndroidInstallRequest, paths: AndroidInstallPaths) -> String {
        let quoted = ([paths.script.path] + arguments(for: request, paths: paths))
            .map(shellQuoted)
            .joined(separator: " ")
        return "/bin/bash \(quoted)"
    }

    /// Resolve the bundled pieces, then run.
    ///
    /// Output is redirected to `logURL` by a wrapper script, because `osascript`'s
    /// `do shell script` only returns once the command has finished; the caller tails the
    /// file to show progress.
    @discardableResult
    public static func run(
        _ request: AndroidInstallRequest,
        logURL: URL
    ) throws -> ShellResult {
        try FileManager.default.createDirectory(at: request.stateDirectory, withIntermediateDirectories: true)

        let script = try AndroidResources.installerScript()
        let certificate = try writeCertificate(request)
        let paths = AndroidInstallPaths(
            script: script,
            certificate: certificate,
            tunnelAPK: AndroidResources.tunnelAPK(),
            magisk: AndroidResources.magiskAssets()
        )

        let wrapper = request.stateDirectory.appendingPathComponent("run.sh")
        let command = commandLine(for: request, paths: paths)
        let contents = """
        #!/bin/sh
        # Generated by ProxyMaxx. Runs the Android installer with output captured so the
        # app can show it while the script is still working.
        \(command) > \(shellQuoted(logURL.path)) 2>&1
        exit $?
        """
        try contents.write(to: wrapper, atomically: true, encoding: .utf8)

        // The Magisk helper reads its consent from standard input, so the app has to supply
        // the answer it already collected from the Magisk toggle. The helper's `adb -n` calls
        // keep their own diagnostics from consuming the same input.
        let consent = request.enableMagisk ? String(repeating: "y\n", count: 4) : ""
        let result = try Shell.run("/bin/sh", [wrapper.path], stdin: consent)
        guard result.succeeded else {
            throw Failure.notRunnable(
                String(format: String(localized: "error.setupScriptFailed", defaultValue: "The setup script exited with status %lld. Review the log above."), Int(result.status))
            )
        }
        return result
    }

    /// Write the CA out as PEM for the script, which hashes it with `openssl x509`. Revert needs
    /// it too, for the same hash: the certificate is installed into the device's user trust
    /// store, so removing it means naming the same file.
    private static func writeCertificate(_ request: AndroidInstallRequest) throws -> URL? {
        guard let pem = request.certificatePEM, !pem.isEmpty else {
            // Revert can still clear the proxy and remove the tunnel app without a certificate,
            // so a proxy that never ran must not fail the whole revert.
            if request.mode == .revert { return nil }
            throw Failure.certificateMissing
        }
        let url = request.stateDirectory.appendingPathComponent("proxymaxx-ca.pem")
        try pem.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// Single-quote for `sh`, which is the one form that cannot be broken by a path.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
