import XCTest
@testable import SystemKit

/// The CLI is read from the app's resources, so the path the panel shows must be the one
/// that actually shipped rather than a guessed checkout location.
final class CLICompanionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("cli-companion-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testBinaryComesFromTheBundlesResources() throws {
        let bundleURL = root.appendingPathComponent("Fake.bundle", isDirectory: true)
        let resources = bundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)
        try """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>test.proxymaxx.fake</string>
            <key>CFBundlePackageType</key>
            <string>BNDL</string>
        </dict>
        </plist>
        """.write(
            to: bundleURL.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let binary = resources.appendingPathComponent(CLICompanion.binaryName)
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let bundle = try XCTUnwrap(Bundle(url: bundleURL))

        XCTAssertEqual(CLICompanion.binaryURL(bundle: bundle).path, binary.path)
    }
}
