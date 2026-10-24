import Foundation
import Branding

/// The macOS side of the browser companion.
///
/// Two small jobs, both mirroring the Android contract in `docs/android-vpn-protocol.md`:
/// keep a state file the native messaging host serves to the extension, and install that
/// host's manifest into each Chromium browser that is actually present. No socket, no
/// daemon — the app configures the companion once and then serves it from a file.
public enum BrowserBridge {
    /// One fixed extension identity, so the host manifest can whitelist its origin.
    ///
    /// This is `key` in `Browser/ProxyMaxxExtension/manifest.json` run through Chrome's
    /// ID derivation (SHA-256 of the SubjectPublicKeyInfo, first 16 bytes, hex mapped
    /// `0-f` onto `a-p`). `Scripts/build-browser-extension.sh` re-derives it and fails if
    /// the two ever disagree.
    public static let extensionID = "cbmoimaniepmlkjbkdpeoeflbhaefeae"

    /// The name both sides agree on: `chrome.runtime.connectNative(BrowserBridge.hostName)`.
    public static let hostName = "com.proxymaxx.browser"

    /// The binary a browser launches. Exported so the installer and the app agree.
    public static let hostBinaryName = "proxymaxx-browser-host"

    public struct State: Codable, Sendable {
        public var version: Int
        public var httpPort: Int
        public var socksPort: Int?
        public var running: Bool
        public var caTrusted: Bool
        public var systemProxy: Bool

        public init(
            version: Int = 1,
            httpPort: Int,
            socksPort: Int?,
            running: Bool,
            caTrusted: Bool,
            systemProxy: Bool
        ) {
            self.version = version
            self.httpPort = httpPort
            self.socksPort = socksPort
            self.running = running
            self.caTrusted = caTrusted
            self.systemProxy = systemProxy
        }
    }

    /// A Chromium browser found on this Mac, under the name its own users recognise it by.
    public struct Browser: Sendable {
        public let name: String
        public let directory: URL

        public init(name: String, directory: URL) {
            self.name = name
            self.directory = directory
        }
    }

    /// A manifest written for one browser, so a caller can name what it reached instead of
    /// reporting a bare count.
    public struct InstalledManifest: Sendable {
        public let browser: String
        public let manifest: URL
    }

    public enum BridgeError: Error, CustomStringConvertible {
        case hostBinaryMissing(URL)
        case hostBinaryNotExecutable(URL)
        case extensionNotBuilt

        public var description: String {
            switch self {
            case .hostBinaryMissing(let url):
                return String(format: String(localized: "error.bridgeNotAt", defaultValue: "The browser bridge binary is not at %@. Build it with `swift build`."), url.path)
            case .hostBinaryNotExecutable(let url):
                return String(format: String(localized: "error.bridgeNotExecutable", defaultValue: "The browser bridge binary at %@ is not executable."), url.path)
            case .extensionNotBuilt:
                return String(localized: "error.extensionNotBuilt", defaultValue: "The browser extension has not been built. Run Scripts/build-browser-extension.sh first.")
            }
        }
    }

    // MARK: - Locations

    public static var supportDirectory: URL {
        Brand.supportDirectory
    }

    public static var stateFileURL: URL {
        supportDirectory.appendingPathComponent("browser-bridge.json")
    }

    /// The binary to launch, next to whatever is running now.
    ///
    /// True for both shapes: `Contents/MacOS/` inside the bundle, and `.build/<config>/`
    /// under `swift run`.
    public static func resolveHostBinary() -> URL? {
        guard let executable = Bundle.main.executableURL else { return nil }
        return executable
            .deletingLastPathComponent()
            .appendingPathComponent(hostBinaryName)
    }

    /// The unpacked extension to load, or nil when it has not been built yet.
    ///
    /// Bundled first; the checkout second, so `swift run` during development finds it.
    public static func extensionFolder() -> URL? {
        if let resources = Bundle.main.resourceURL {
            let bundled = resources
                .appendingPathComponent("Browser", isDirectory: true)
                .appendingPathComponent(extensionFolderName, isDirectory: true)
            if FileManager.default.fileExists(atPath: bundled.path) { return bundled }
        }
        // Sources/SystemKit/BrowserBridge.swift -> the package root.
        let packageRoot = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
        let checkout = packageRoot.appendingPathComponent("Browser/ProxyMaxxExtension", isDirectory: true)
        return FileManager.default.fileExists(atPath: checkout.path) ? checkout : nil
    }

    /// The folder name a browser sees, staged and installed alike.
    public static let extensionFolderName = "proxymaxx-extension"

    /// Where the extension is installed for the browser to load.
    ///
    /// Deliberately outside the app bundle. Finder refuses to reveal a path inside a
    /// `.app` — it selects the bundle instead — and Chrome remembers this path, so it must
    /// not be a location that the next `bundle-app.sh` replaces.
    public static var installedExtensionDirectory: URL {
        supportDirectory
            .appendingPathComponent("Browser Extension", isDirectory: true)
            .appendingPathComponent(extensionFolderName, isDirectory: true)
    }

    /// Copy the built extension to the location the browser loads it from.
    ///
    /// Returns that location, so the caller can reveal it and name it. This is the part of
    /// "install" the user can see; the host manifests are invisible by nature.
    @discardableResult
    public static func installExtension() throws -> URL {
        guard let source = extensionFolder() else { throw BridgeError.extensionNotBuilt }
        return try copyExtension(from: source, to: installedExtensionDirectory)
    }

    /// Copy a built extension into place, replacing whatever is already there.
    ///
    /// Wholesale, never merged: a file left behind by an older build is loaded by the
    /// browser as though it were current, which is how a stale service worker survives an
    /// update.
    static func copyExtension(from source: URL, to destination: URL) throws -> URL {
        try FileManager.default.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: source, to: destination)
        return destination
    }

    // MARK: - State

    /// Publish the proxy's state for the extension to read. Failure is not fatal: the
    /// extension reports "app not running" and keeps working.
    @discardableResult
    public static func publish(_ state: State) -> Bool {
        do {
            try FileManager.default.createDirectory(at: supportDirectory, withIntermediateDirectories: true)
            let encoder = JSONEncoder()
            encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
            let data = try encoder.encode(state)
            try data.write(to: stateFileURL, options: .atomic)
            return true
        } catch {
            return false
        }
    }

    // MARK: - Native messaging host

    /// Every Chromium browser present on this Mac, newest profile first, but only those
    /// whose profile directory exists.
    public static func detectedBrowsers() -> [Browser] {
        let applicationSupport = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")

        let profiles: [(name: String, path: String)] = [
            ("Chrome", "Google/Chrome"),
            ("Chrome Beta", "Google/Chrome Beta"),
            ("Chrome Dev", "Google/Chrome Dev"),
            ("Chrome Canary", "Google/Chrome Canary"),
            ("Chromium", "Chromium"),
            ("Brave", "BraveSoftware/Brave-Browser"),
            ("Brave Beta", "BraveSoftware/Brave-Browser-Beta"),
            ("Edge", "Microsoft Edge"),
            ("Edge Beta", "Microsoft Edge Beta"),
            ("Edge Dev", "Microsoft Edge Dev"),
            ("Edge Canary", "Microsoft Edge Canary"),
            ("Vivaldi", "Vivaldi"),
        ]

        return profiles.compactMap { profile in
            let root = applicationSupport.appendingPathComponent(profile.path, isDirectory: true)
            guard FileManager.default.fileExists(atPath: root.path) else { return nil }
            return Browser(
                name: profile.name,
                directory: root.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
            )
        }
    }

    /// The native messaging directories of those browsers.
    public static func nativeMessagingDirectories() -> [URL] {
        detectedBrowsers().map(\.directory)
    }

    /// Write the host manifest into every browser given.
    ///
    /// Returns what was written so the caller can report which browsers were reached
    /// instead of claiming a blanket success. The browser list is a parameter so a caller
    /// can install somewhere specific, and so this is testable without writing into the
    /// real browsers.
    @discardableResult
    public static func installNativeMessagingHost(
        hostBinary: URL,
        browsers: [Browser] = detectedBrowsers()
    ) throws -> [InstalledManifest] {
        guard FileManager.default.fileExists(atPath: hostBinary.path) else {
            throw BridgeError.hostBinaryMissing(hostBinary)
        }
        guard FileManager.default.isExecutableFile(atPath: hostBinary.path) else {
            throw BridgeError.hostBinaryNotExecutable(hostBinary)
        }

        let manifest: [String: Any] = [
            "name": hostName,
            "description": "ProxyMaxx browser bridge",
            "path": hostBinary.path,
            "type": "stdio",
            "allowed_origins": ["chrome-extension://\(extensionID)/"],
        ]
        let data = try JSONSerialization.data(withJSONObject: manifest, options: [.prettyPrinted, .sortedKeys])

        var written: [InstalledManifest] = []
        for browser in browsers {
            do {
                try FileManager.default.createDirectory(at: browser.directory, withIntermediateDirectories: true)
                let target = browser.directory.appendingPathComponent("\(hostName).json")
                try data.write(to: target, options: .atomic)
                written.append(InstalledManifest(browser: browser.name, manifest: target))
            } catch {
                // One browser refusing is not a reason to abandon the rest.
                continue
            }
        }
        return written
    }

    /// Remove the host manifests. Used when the app is asked to leave no trace.
    @discardableResult
    public static func removeNativeMessagingHost(browsers: [Browser] = detectedBrowsers()) -> [URL] {
        var removed: [URL] = []
        for browser in browsers {
            let target = browser.directory.appendingPathComponent("\(hostName).json")
            guard FileManager.default.fileExists(atPath: target.path) else { continue }
            if (try? FileManager.default.removeItem(at: target)) != nil {
                removed.append(target)
            }
        }
        return removed
    }

    // MARK: - Verification

    /// What running the host once, the way a browser does, revealed.
    public enum HostCheck: Sendable {
        /// The host answered. `port` is nil when no engine has published state yet, which
        /// means the bridge works and there is simply nothing to point a browser at.
        case answered(port: Int?)
        case failed(String)
    }

    /// Run the host exactly as a browser would and report what came back.
    ///
    /// The host manifest is invisible and its failure is silent: the browser loads, the
    /// extension renders, and the only symptom is a popup saying the app cannot be reached,
    /// with nothing on this side to explain it. So installing the bridge proves the bridge,
    /// rather than assuming a file that was written is a channel that works.
    public static func verifyHost(hostBinary: URL, timeout: TimeInterval = 3) -> HostCheck {
        guard FileManager.default.fileExists(atPath: hostBinary.path) else {
            return .failed(String(format: String(localized: "error.bridgeNotAt", defaultValue: "The browser bridge binary is not at %@. Build it with `swift build`."), hostBinary.path))
        }
        guard FileManager.default.isExecutableFile(atPath: hostBinary.path) else {
            return .failed(String(format: String(localized: "error.bridgeNotExecutable", defaultValue: "The browser bridge binary at %@ is not executable."), hostBinary.path))
        }

        let process = Process()
        process.executableURL = hostBinary
        // The origin a browser passes as the first argument, so a host that grows an origin
        // check is exercised here too.
        process.arguments = ["chrome-extension://\(extensionID)/"]

        let input = Pipe()
        let output = Pipe()
        process.standardInput = input
        process.standardOutput = output
        process.standardError = FileHandle.nullDevice

        do {
            try process.run()
        } catch {
            return .failed("\(error)")
        }

        // The host answers one message and exits when stdin closes, so writing the request
        // and closing the pipe is what ends it. No timeout bookkeeping on the happy path.
        let request = (try? JSONSerialization.data(withJSONObject: ["type": "hello"])) ?? Data()
        var framed = Data()
        withUnsafeBytes(of: UInt32(request.count).littleEndian) { framed.append(contentsOf: $0) }
        framed.append(request)
        try? input.fileHandleForWriting.write(contentsOf: framed)
        try? input.fileHandleForWriting.close()

        // A host that never answers must not hang the install, so a watchdog ends it.
        let watchdog = DispatchWorkItem {
            if process.isRunning { process.terminate() }
        }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        let header = read(output.fileHandleForReading, count: 4)
        guard header.count == 4 else {
            process.waitUntilExit()
            return .failed(String(localized: "error.bridgeNoReply", defaultValue: "The browser bridge exited without answering."))
        }

        let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
        let body = read(output.fileHandleForReading, count: Int(length))
        process.waitUntilExit()

        guard let reply = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] else {
            return .failed(String(localized: "error.bridgeUnreadable", defaultValue: "The browser bridge answered with something that is not JSON."))
        }
        guard reply["ok"] as? Bool == true else {
            // "app_not_running" is a working bridge with nothing published yet, which is not
            // a broken bridge and must not be reported as one.
            if reply["reason"] as? String == "app_not_running" { return .answered(port: nil) }
            return .failed(reply["reason"] as? String ?? "unknown")
        }
        return .answered(port: reply["httpPort"] as? Int)
    }

    /// Read up to `count` bytes, returning fewer only at end of stream.
    ///
    /// A pipe hands back whatever has arrived, so one read is not one message.
    private static func read(_ handle: FileHandle, count: Int) -> Data {
        var data = Data()
        while data.count < count {
            let chunk = handle.readData(ofLength: count - data.count)
            if chunk.isEmpty { break }
            data.append(chunk)
        }
        return data
    }
}
