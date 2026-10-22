import Foundation

/// One device as `adb devices -l` reports it.
public struct AndroidDevice: Sendable, Identifiable, Hashable {
    public let serial: String
    public let model: String

    public var id: String { serial }

    /// Android Studio AVDs are named `emulator-<console-port>`. Anything else is a real
    /// device or a third-party emulator, which is treated as a physical device.
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    public var displayName: String {
        model.isEmpty ? serial : "\(model) (\(serial))"
    }
}

/// Locating, and talking to, the Android SDK from the Mac.
///
/// Everything here is deliberately read-only: the tool paths are resolved the same way the
/// installer resolves them, so the guide can tell the user what it is about to use before
/// anything runs.
public enum AndroidToolchain {
    /// The SDK root, if one can be found.
    public static func sdkRoot() -> URL? {
        for candidate in [
            ProcessInfo.processInfo.environment["ANDROID_SDK_ROOT"],
            ProcessInfo.processInfo.environment["ANDROID_HOME"],
            "\(NSHomeDirectory())/Library/Android/sdk",
            "\(NSHomeDirectory())/Android/Sdk",
        ] {
            guard let candidate, !candidate.isEmpty else { continue }
            let url = URL(fileURLWithPath: candidate)
            if FileManager.default.fileExists(atPath: url.appendingPathComponent("platform-tools/adb").path) {
                return url
            }
        }
        return nil
    }

    /// The adb executable, preferring Android Studio's SDK.
    ///
    /// Android Studio's copy comes first on purpose: a Homebrew adb can restart the adb
    /// server part-way through setup and make a healthy emulator disappear.
    public static func adbPath() -> String? {
        if let root = sdkRoot() {
            let adb = root.appendingPathComponent("platform-tools/adb")
            if FileManager.default.isExecutableFile(atPath: adb.path) { return adb.path }
        }
        for path in ["/opt/homebrew/bin/adb", "/usr/local/bin/adb"] where FileManager.default.isExecutableFile(atPath: path) {
            return path
        }
        if let result = try? Shell.run("/usr/bin/which", ["adb"]), result.succeeded {
            let path = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !path.isEmpty, FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return nil
    }

    /// The emulator executable, needed by the Magisk route to cold-start the AVD itself.
    public static func emulatorPath() -> String? {
        if let root = sdkRoot() {
            let emulator = root.appendingPathComponent("emulator/emulator")
            if FileManager.default.isExecutableFile(atPath: emulator.path) { return emulator.path }
        }
        return nil
    }

    /// Every connected device, or an empty list when adb is unavailable.
    public static func devices() -> [AndroidDevice] {
        guard let adb = adbPath(),
              let result = try? Shell.run(adb, ["devices", "-l"]),
              result.succeeded else {
            return []
        }
        return parseDevices(result.output)
    }

    /// Parse `adb devices -l` output. Split out so it can be tested without a device.
    static func parseDevices(_ output: String) -> [AndroidDevice] {
        var devices: [AndroidDevice] = []
        for line in output.split(separator: "\n") {
            let fields = line.split(separator: " ").map(String.init)
            // A usable row is "<serial> device ..."; anything else (offline, unauthorized,
            // or the header) is not something we can install onto.
            guard fields.count >= 2, fields[1] == "device" else { continue }
            let serial = fields[0]
            let model = fields.first { $0.hasPrefix("model:") }
                .map { String($0.dropFirst("model:".count)).replacingOccurrences(of: "_", with: " ") } ?? ""
            devices.append(AndroidDevice(serial: serial, model: model))
        }
        return devices
    }

    /// The address the device must use to reach this Mac.
    ///
    /// An emulator always reaches its host as `10.0.2.2`; a real device needs the Mac's LAN
    /// address, because it is a separate machine on the network.
    public static func hostAddress(forEmulator isEmulator: Bool) -> String {
        isEmulator ? "10.0.2.2" : (lanIPv4Address() ?? "10.0.2.2")
    }

    /// The Mac's LAN address, for physical devices.
    public static func lanIPv4Address() -> String? {
        for interface in ["en0", "en1"] {
            guard let result = try? Shell.run("/usr/sbin/ipconfig", ["getifaddr", interface]),
                  result.succeeded else { continue }
            let address = result.output.trimmingCharacters(in: .whitespacesAndNewlines)
            if !address.isEmpty { return address }
        }
        return nil
    }
}
