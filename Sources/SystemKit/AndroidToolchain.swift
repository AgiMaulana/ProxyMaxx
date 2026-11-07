import Foundation

/// One device as `adb devices -l` reports it.
public struct AndroidDevice: Sendable, Identifiable, Hashable {
    public let serial: String
    public let model: String

    public init(serial: String, model: String) {
        self.serial = serial
        self.model = model
    }

    public var id: String { serial }

    /// Android Studio AVDs are named `emulator-<console-port>`. Anything else is a real
    /// device or a third-party emulator, which is treated as a physical device.
    public var isEmulator: Bool { serial.hasPrefix("emulator-") }

    /// The headline the guide lists a device under. `adb devices -l` reports a generic model
    /// for every emulator (`sdk gphone64 arm64`), so a device is named by its model and an
    /// emulator by its serial, never by a product name adb did not give.
    public var titleLine: String {
        guard !isEmulator else { return serial }
        return model.isEmpty ? serial : model
    }

    /// The second line. The model is kept for an emulator where the headline is the serial.
    public var subtitleLine: String {
        guard isEmulator else { return serial }
        return model.isEmpty ? serial : model
    }

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

    /// The serials in `list` whose emulator is actually running.
    ///
    /// `adb devices -l` remembers an emulator after its process is gone, and reports no
    /// version or image, so this is the one per-device fact the guide can state without
    /// either shelling into the device or guessing. A physical device is taken as running.
    public static func runningSerials(in list: [AndroidDevice]) -> Set<String> {
        Set(list.filter { device in
            guard let console = consolePort(forSerial: device.serial) else { return true }
            return isListeningOnLoopback(port: console)
        }.map(\.serial))
    }

    /// Whether the ADB shell on `serial` is already root. Read-only: it changes nothing on
    /// the device, and is what lets the guide say a setup is in place rather than imply it.
    public static func hasRootShell(serial: String) -> Bool {
        guard let adb = adbPath(),
              let result = try? Shell.run(adb, ["-s", serial, "shell", "id", "-u"]),
              result.succeeded else {
            return false
        }
        return result.output.trimmingCharacters(in: .whitespacesAndNewlines) == "0"
    }

    /// The device to act on when none is named: the first emulator, else the first
    /// attached device. The guide and the CLI both use this, so they target the same one.
    public static func preferredDevice(in devices: [AndroidDevice]) -> AndroidDevice? {
        devices.first(where: \.isEmulator) ?? devices.first
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

    /// True for the address an Android emulator's network reaches this Mac from.
    public static func isEmulatorAddress(_ peer: String) -> Bool {
        peer == "10.0.2.2"
    }

    /// The emulator console port `adb devices -l` lists as this serial, or nil when the serial
    /// is not an emulator or is out of range.
    ///
    /// An emulator's serial is its console port (`emulator-5554`); odd serials seen in the
    /// wild are rounded down to the even console port they belong to.
    public static func consolePort(forSerial serial: String) -> Int? {
        guard serial.hasPrefix("emulator-"),
              let port = Int(serial.dropFirst("emulator-".count)),
              (1...65_535).contains(port) else { return nil }
        return port % 2 == 0 ? port : port - 1
    }

    /// Whether something on this Mac accepts a connection on `127.0.0.1:port` right now.
    ///
    /// `adb devices -l` keeps listing an emulator after its process is gone, so the listing
    /// alone cannot tell a running emulator from a stale entry. The console port is bound only
    /// while the emulator runs, so a refused connection there is the evidence that it stopped.
    public static func isListeningOnLoopback(port: Int, timeoutMilliseconds: Int32 = 200) -> Bool {
        var hints = addrinfo(
            ai_flags: 0, ai_family: AF_INET, ai_socktype: SOCK_STREAM, ai_protocol: 0,
            ai_addrlen: 0, ai_canonname: nil, ai_addr: nil, ai_next: nil
        )
        var info: UnsafeMutablePointer<addrinfo>?
        guard getaddrinfo("127.0.0.1", String(port), &hints, &info) == 0, let first = info else { return false }
        defer { freeaddrinfo(info) }
        let descriptor = socket(AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { return false }
        defer { close(descriptor) }
        // Without a send timeout a connect through a stale firewall rule can hang.
        var timeout = timeval(tv_sec: 0, tv_usec: timeoutMilliseconds * 1000)
        setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout, socklen_t(MemoryLayout<timeval>.size))
        return connect(descriptor, first.pointee.ai_addr, first.pointee.ai_addrlen) == 0
    }

    /// The connected devices whose emulator is still running.
    ///
    /// `devices()` reports what adb remembers; `runningDevices()` reports what is alive,
    /// which is what the traffic sidebar should name as a connected emulator.
    public static func runningDevices() -> [AndroidDevice] {
        devices().filter { device in
            guard let console = consolePort(forSerial: device.serial) else { return true }
            return isListeningOnLoopback(port: console)
        }
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
