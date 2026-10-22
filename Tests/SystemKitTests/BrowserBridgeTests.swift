import XCTest
@testable import SystemKit

/// The install has to be visible to the user and honest about what it reached. It writes
/// files nobody sees, into directories several browsers share, so the interesting cases are
/// what it does when a browser refuses, and whether a stale build is really replaced.
final class BrowserBridgeTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("browser-bridge-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func writeStagedExtension(named name: String = "staged", files: [String: String]) throws -> URL {
        let folder = root.appendingPathComponent(name, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        for (file, contents) in files {
            try contents.write(to: folder.appendingPathComponent(file), atomically: true, encoding: .utf8)
        }
        return folder
    }

    /// A stand-in for the host binary: the installer only checks that it exists and can run.
    private func executableHost() throws -> URL {
        let url = root.appendingPathComponent("proxymaxx-browser-host")
        try "#!/bin/sh\n".write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: - Staging the extension

    func testCopyInstallsTheExtensionUnderTheGivenDestination() throws {
        let source = try writeStagedExtension(files: ["manifest.json": "{}", "popup.js": "// panel"])
        let destination = root.appendingPathComponent("Browser Extension/\(BrowserBridge.extensionFolderName)")

        let installed = try BrowserBridge.copyExtension(from: source, to: destination)

        XCTAssertEqual(installed, destination)
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: installed.path).sorted(),
            ["manifest.json", "popup.js"]
        )
    }

    /// A rebuild must not leave last version's files behind: the browser loads whatever it
    /// finds, and a stale service worker would outlive the update that replaced it.
    func testCopyReplacesTheDestinationWholesale() throws {
        let source = try writeStagedExtension(files: ["manifest.json": "new"])
        let destination = root.appendingPathComponent("installed", isDirectory: true)
        try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
        try "old".write(
            to: destination.appendingPathComponent("leftover.js"),
            atomically: true,
            encoding: .utf8
        )

        try BrowserBridge.copyExtension(from: source, to: destination)

        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: destination.path),
            ["manifest.json"]
        )
    }

    func testCopyCreatesMissingIntermediateDirectories() throws {
        let source = try writeStagedExtension(files: ["manifest.json": "{}"])
        let destination = root.appendingPathComponent("a/b/c/installed", isDirectory: true)

        XCTAssertNoThrow(try BrowserBridge.copyExtension(from: source, to: destination))
        XCTAssertTrue(FileManager.default.fileExists(atPath: destination.path))
    }

    // MARK: - Host manifests

    func testInstallWritesTheManifestEachBrowserCanAuthorise() throws {
        let host = try executableHost()
        let chrome = BrowserBridge.Browser(
            name: "Chrome",
            directory: root.appendingPathComponent("Chrome/NativeMessagingHosts", isDirectory: true)
        )

        let written = try BrowserBridge.installNativeMessagingHost(hostBinary: host, browsers: [chrome])

        XCTAssertEqual(written.map(\.browser), ["Chrome"])
        let data = try Data(contentsOf: written[0].manifest)
        let manifest = try XCTUnwrap(
            JSONSerialization.jsonObject(with: data) as? [String: Any]
        )
        XCTAssertEqual(manifest["name"] as? String, BrowserBridge.hostName)
        XCTAssertEqual(manifest["path"] as? String, host.path)
        XCTAssertEqual(manifest["type"] as? String, "stdio")
        // The one entry that makes the extension's origin allowed to talk to the host.
        XCTAssertEqual(
            manifest["allowed_origins"] as? [String],
            ["chrome-extension://\(BrowserBridge.extensionID)/"]
        )
    }

    func testInstallNamesEveryBrowserItReached() throws {
        let host = try executableHost()
        let browsers = ["Chrome", "Brave", "Edge"].map {
            BrowserBridge.Browser(
                name: $0,
                directory: root.appendingPathComponent("\($0)/NativeMessagingHosts", isDirectory: true)
            )
        }

        let written = try BrowserBridge.installNativeMessagingHost(hostBinary: host, browsers: browsers)

        XCTAssertEqual(written.map(\.browser), ["Chrome", "Brave", "Edge"])
    }

    /// One browser refusing must not abandon the others, and — since the caller reports the
    /// count — it must not be counted either.
    func testABrowserThatCannotBeWrittenIsSkippedNotCounted() throws {
        let host = try executableHost()
        let good = BrowserBridge.Browser(
            name: "Chrome",
            directory: root.appendingPathComponent("Chrome/NativeMessagingHosts", isDirectory: true)
        )
        // A file where the directory should be: creating the directory cannot succeed.
        let blockedPath = root.appendingPathComponent("blocked")
        try "not a directory".write(to: blockedPath, atomically: true, encoding: .utf8)
        let blocked = BrowserBridge.Browser(
            name: "Edge",
            directory: blockedPath.appendingPathComponent("NativeMessagingHosts", isDirectory: true)
        )

        let written = try BrowserBridge.installNativeMessagingHost(hostBinary: host, browsers: [good, blocked])

        XCTAssertEqual(written.map(\.browser), ["Chrome"])
    }

    /// The app reports a missing binary as an error rather than writing a manifest that
    /// points at nothing, which would fail later inside the browser with no explanation.
    func testInstallRefusesAMissingHostBinary() throws {
        let missing = root.appendingPathComponent("absent/proxymaxx-browser-host")

        XCTAssertThrowsError(
            try BrowserBridge.installNativeMessagingHost(hostBinary: missing, browsers: [])
        ) { error in
            guard case BrowserBridge.BridgeError.hostBinaryMissing = error else {
                return XCTFail("expected hostBinaryMissing, got \(error)")
            }
        }
    }

    func testInstallRefusesAHostBinaryThatCannotRun() throws {
        let notExecutable = root.appendingPathComponent("proxymaxx-browser-host")
        try "#!/bin/sh\n".write(to: notExecutable, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: notExecutable.path)

        XCTAssertThrowsError(
            try BrowserBridge.installNativeMessagingHost(hostBinary: notExecutable, browsers: [])
        ) { error in
            guard case BrowserBridge.BridgeError.hostBinaryNotExecutable = error else {
                return XCTFail("expected hostBinaryNotExecutable, got \(error)")
            }
        }
    }

    func testRemoveDeletesOnlyTheManifestsItOwns() throws {
        let host = try executableHost()
        let directory = root.appendingPathComponent("Chrome/NativeMessagingHosts", isDirectory: true)
        let browser = BrowserBridge.Browser(name: "Chrome", directory: directory)
        try BrowserBridge.installNativeMessagingHost(hostBinary: host, browsers: [browser])
        // Another extension's manifest, which is none of our business.
        try "{}".write(
            to: directory.appendingPathComponent("com.example.something-else.json"),
            atomically: true,
            encoding: .utf8
        )

        let removed = BrowserBridge.removeNativeMessagingHost(browsers: [browser])

        XCTAssertEqual(removed.map(\.lastPathComponent), ["\(BrowserBridge.hostName).json"])
        XCTAssertEqual(
            try FileManager.default.contentsOfDirectory(atPath: directory.path),
            ["com.example.something-else.json"]
        )
    }

    // MARK: - Locations

    /// Kept next to the state file rather than inside the app bundle: Finder will not reveal
    /// a path inside a `.app`, and a browser remembers this path across app rebuilds.
    func testTheInstalledExtensionLivesOutsideAnyApplicationBundle() {
        let path = BrowserBridge.installedExtensionDirectory.path

        XCTAssertTrue(path.hasSuffix("Application Support/ProxyMaxx/Browser Extension/proxymaxx-extension"))
        XCTAssertFalse(path.contains(".app/"))
    }
}
