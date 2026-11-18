import XCTest
@testable import SystemKit
import Branding

final class InstalledVersionTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("installed-version-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    func testInstalledVersionResolvesFromEnclosingAppBundle() throws {
        let appBundleURL = root.appendingPathComponent("ProxyMaxx.app", isDirectory: true)
        let resources = appBundleURL.appendingPathComponent("Contents/Resources", isDirectory: true)
        try FileManager.default.createDirectory(at: resources, withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(Brand.bundleIdentifier)</string>
            <key>CFBundleShortVersionString</key>
            <string>1.2.3</string>
            <key>CFBundleVersion</key>
            <string>123</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plistContent.write(
            to: appBundleURL.appendingPathComponent("Contents/Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let binary = resources.appendingPathComponent("proxymaxx-cli")
        try "#!/bin/sh\n".write(to: binary, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binary.path)

        let resolved = InstalledVersion.resolveAppBundle(
            executableURL: binary,
            applicationsDirectory: "/nonexistent",
            caskroomDirectories: []
        )
        XCTAssertNotNil(resolved)
        XCTAssertEqual(resolved?.bundleURL.path, appBundleURL.path)

        let info = InstalledVersion.info(
            executableURL: binary,
            applicationsDirectory: "/nonexistent",
            caskroomDirectories: []
        )
        XCTAssertTrue(info.isBundled)
        XCTAssertEqual(info.version, "1.2.3")
        XCTAssertEqual(info.build, "123")
        XCTAssertEqual(info.releaseVersion, ReleaseVersion("1.2.3"))
        XCTAssertEqual(info.displayString, "\(Brand.displayName) 1.2.3 (build 123)")
    }

    func testInstalledVersionResolvesFromApplicationsDirectory() throws {
        let appsDir = root.appendingPathComponent("Applications", isDirectory: true)
        let appBundleURL = appsDir.appendingPathComponent(InstallOriginDetector.appBundleName, isDirectory: true)
        let contents = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(Brand.bundleIdentifier)</string>
            <key>CFBundleShortVersionString</key>
            <string>2.4.6</string>
            <key>CFBundleVersion</key>
            <string>246</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plistContent.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let detachedBinary = root.appendingPathComponent("bin/proxymaxx-cli")
        try FileManager.default.createDirectory(at: detachedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: detachedBinary, atomically: true, encoding: .utf8)

        let info = InstalledVersion.info(
            executableURL: detachedBinary,
            applicationsDirectory: appsDir.path,
            caskroomDirectories: []
        )
        XCTAssertTrue(info.isBundled)
        XCTAssertEqual(info.version, "2.4.6")
        XCTAssertEqual(info.build, "246")
        XCTAssertEqual(info.displayString, "\(Brand.displayName) 2.4.6 (build 246)")
    }

    func testInstalledVersionResolvesFromCaskroomDirectory() throws {
        let caskroom = root.appendingPathComponent("Caskroom", isDirectory: true)
        let versionDir = caskroom.appendingPathComponent("proxymaxx/3.0.0", isDirectory: true)
        let appBundleURL = versionDir.appendingPathComponent(InstallOriginDetector.appBundleName, isDirectory: true)
        let contents = appBundleURL.appendingPathComponent("Contents", isDirectory: true)
        try FileManager.default.createDirectory(at: contents, withIntermediateDirectories: true)

        let plistContent = """
        <?xml version="1.0" encoding="UTF-8"?>
        <!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
        <plist version="1.0">
        <dict>
            <key>CFBundleIdentifier</key>
            <string>\(Brand.bundleIdentifier)</string>
            <key>CFBundleShortVersionString</key>
            <string>3.0.0</string>
            <key>CFBundlePackageType</key>
            <string>APPL</string>
        </dict>
        </plist>
        """
        try plistContent.write(
            to: contents.appendingPathComponent("Info.plist"),
            atomically: true,
            encoding: .utf8
        )

        let detachedBinary = root.appendingPathComponent("bin/proxymaxx-cli")
        try FileManager.default.createDirectory(at: detachedBinary.deletingLastPathComponent(), withIntermediateDirectories: true)
        try "#!/bin/sh\n".write(to: detachedBinary, atomically: true, encoding: .utf8)

        let info = InstalledVersion.info(
            executableURL: detachedBinary,
            applicationsDirectory: "/nonexistent",
            caskroomDirectories: [caskroom]
        )
        XCTAssertTrue(info.isBundled)
        XCTAssertEqual(info.version, "3.0.0")
        XCTAssertNil(info.build)
        XCTAssertEqual(info.displayString, "\(Brand.displayName) 3.0.0")
    }

    func testInstalledVersionInfoDisplayStrings() {
        let bundledWithBuild = InstalledVersionInfo(version: "1.0.0", build: "42", isBundled: true)
        XCTAssertEqual(bundledWithBuild.displayString, "\(Brand.displayName) 1.0.0 (build 42)")

        let bundledWithoutBuild = InstalledVersionInfo(version: "1.0.0", build: nil, isBundled: true)
        XCTAssertEqual(bundledWithoutBuild.displayString, "\(Brand.displayName) 1.0.0")

        let unbundledWithVersion = InstalledVersionInfo(version: "0.1.0", build: nil, isBundled: false)
        XCTAssertEqual(unbundledWithVersion.displayString, "\(Brand.displayName) 0.1.0 (unbundled)")

        let unbundledDev = InstalledVersionInfo(version: "dev", build: nil, isBundled: false)
        XCTAssertEqual(unbundledDev.displayString, "\(Brand.displayName) (unbundled)")
    }
}
