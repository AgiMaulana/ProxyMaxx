import Foundation

/// The bundled Magisk assets, for the Google Play AVD route.
public struct AndroidMagiskAssets: Sendable {
    public let version: String
    public let apk: URL
    public let hostPatch: URL
    public let script: URL
}

public enum AndroidResourceError: Error, CustomStringConvertible {
    case resourcesMissing
    case missingScript(URL)
    case missingMagisk(URL)

    public var description: String {
        switch self {
        case .resourcesMissing:
            return String(localized: "error.androidResourcesMissing", defaultValue: "The Android resources are missing from this build. Rebuild with Scripts/bundle-app.sh, or set PROXYMAXX_RESOURCES.")
        case .missingScript(let url):
            return String(format: String(localized: "error.androidScriptMissing", defaultValue: "The Android installer script was not found at %@."), url.path)
        case .missingMagisk(let url):
            return String(format: String(localized: "error.magiskAssetsMissing", defaultValue: "PM-MAGISK-RESOURCE-001: the bundled Magisk assets are missing at %@."), url.path)
        }
    }
}

/// Finds the shell scripts and the tunnel APK, whether the app runs from a bundle or from
/// `swift run` inside the checkout.
public enum AndroidResources {
    public static let magiskVersion = "30.7"

    /// Candidate directories, in the order they are trusted.
    ///
    /// The environment override exists so the feature can be exercised against a working
    /// copy without rebuilding the bundle.
    static func candidateDirectories() -> [URL] {
        var directories: [URL] = []

        if let override = ProcessInfo.processInfo.environment["PROXYMAXX_RESOURCES"], !override.isEmpty {
            directories.append(URL(fileURLWithPath: override))
        }
        if let resourceURL = Bundle.main.resourceURL {
            directories.append(resourceURL.appendingPathComponent("Android"))
            directories.append(resourceURL.appendingPathComponent("android"))
        }
        // Development fallback: this file lives at <repo>/ProxyMaxx/Sources/SystemKit/,
        // so three levels up is the package root. Only reached when nothing is bundled.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SystemKit
            .deletingLastPathComponent()   // Sources
            .deletingLastPathComponent()   // ProxyMaxx
        directories.append(packageRoot.appendingPathComponent("Resources/android"))

        return directories
    }

    /// The directory holding the Android resources.
    public static func directory() -> URL? {
        candidateDirectories().first {
            FileManager.default.fileExists(atPath: $0.appendingPathComponent("install_certificate_android_emulator.sh").path)
        }
    }

    /// The installer script.
    public static func installerScript() throws -> URL {
        guard let directory = directory() else { throw AndroidResourceError.resourcesMissing }
        let script = directory.appendingPathComponent("install_certificate_android_emulator.sh")
        guard FileManager.default.fileExists(atPath: script.path) else {
            throw AndroidResourceError.missingScript(script)
        }
        return script
    }

    /// The tunnel APK, when one has been built into the app.
    ///
    /// Produced by `Scripts/build-android-vpn.sh`. Absence is not an error: the certificate
    /// and proxy steps work without it, and the guide says how to create it.
    public static func tunnelAPK() -> URL? {
        guard let directory = directory() else { return nil }
        let apk = directory.appendingPathComponent("proxymaxx-vpn.apk")
        return FileManager.default.fileExists(atPath: apk.path) ? apk : nil
    }

    /// The Magisk assets, or nil when they were not bundled.
    public static func magiskAssets() -> AndroidMagiskAssets? {
        guard let directory = directory() else { return nil }
        let magiskDirectory = directory
            .appendingPathComponent("Magisk")
            .appendingPathComponent("v\(magiskVersion)")

        let apk = magiskDirectory.appendingPathComponent("Magisk-v\(magiskVersion).apk")
        let hostPatch = magiskDirectory.appendingPathComponent("host_patch.sh")
        let script = directory.appendingPathComponent("install_certificate_android_emulator_magisk.sh")

        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: apk.path),
              fileManager.fileExists(atPath: hostPatch.path),
              fileManager.fileExists(atPath: script.path) else {
            return nil
        }

        return AndroidMagiskAssets(version: magiskVersion, apk: apk, hostPatch: hostPatch, script: script)
    }
}
