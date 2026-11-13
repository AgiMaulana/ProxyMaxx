import XCTest
@testable import PluginKit

final class PluginSemverTests: XCTestCase {
    func testParsesVersionsWithOptionalComponents() {
        XCTAssertEqual(PluginSemver(parsing: "1"), PluginSemver(major: 1))
        XCTAssertEqual(PluginSemver(parsing: "1.2"), PluginSemver(major: 1, minor: 2))
        XCTAssertEqual(PluginSemver(parsing: "1.2.3"), PluginSemver(major: 1, minor: 2, patch: 3))
        XCTAssertEqual(PluginSemver(parsing: "1.2.3-beta.1"), PluginSemver(major: 1, minor: 2, patch: 3))
        XCTAssertNil(PluginSemver(parsing: "1.x"))
        XCTAssertNil(PluginSemver(parsing: ""))
        XCTAssertNil(PluginSemver(parsing: "1.2.3.4"))
    }

    func testRangeForms() {
        func contains(_ range: String, _ version: String) -> Bool {
            PluginSemverRange(parsing: range)?.contains(PluginSemver(parsing: version)!) ?? false
        }
        XCTAssertTrue(contains("*", "99.0.0"))
        XCTAssertTrue(contains("1.2.3", "1.2.3"))
        XCTAssertFalse(contains("1.2.3", "1.2.4"))
        XCTAssertTrue(contains("^1.2.3", "1.9.9"))
        XCTAssertFalse(contains("^1.2.3", "2.0.0"))
        XCTAssertTrue(contains("^0.2.3", "0.2.9"))
        XCTAssertFalse(contains("^0.2.3", "0.3.0"))
        XCTAssertTrue(contains("~1.2.3", "1.2.9"))
        XCTAssertFalse(contains("~1.2.3", "1.3.0"))
        XCTAssertTrue(contains(">=1.2.3", "1.2.3"))
        XCTAssertTrue(contains("<2.0.0", "1.9.0"))
        XCTAssertFalse(contains("<1.2.3", "1.2.3"))
        XCTAssertTrue(contains("1.0.0 - 2.0.0", "2.0.0"))
        XCTAssertFalse(contains("1.0.0 - 2.0.0", "2.0.1"))
        XCTAssertTrue(contains(">=1.0.0 <2.0.0", "1.5.0"))
        XCTAssertFalse(contains(">=1.0.0 <2.0.0", "2.0.0"))
        XCTAssertNil(PluginSemverRange(parsing: "bogus"))
        XCTAssertNil(PluginSemverRange(parsing: ""))
    }

    func testHostSDKCompatibility() {
        let manifest = PluginFixtures.manifest(sdkVersion: "^1.0.0")
        XCTAssertTrue(manifest.isCompatibleWithHostSDK())
        let tooNew = PluginFixtures.manifest(sdkVersion: "^\(PluginSDK.version.split(separator: ".").first! + ".9999")")
        XCTAssertFalse(tooNew.isCompatibleWithHostSDK())
        let exact = PluginFixtures.manifest(sdkVersion: PluginSDK.version)
        XCTAssertTrue(exact.isCompatibleWithHostSDK())
    }
}

final class PluginManifestValidationTests: XCTestCase {
    func testValidManifestPasses() throws {
        try PluginFixtures.manifest().validated()
    }

    func testUnsupportedFormatVersionIsRejected() {
        var manifest = PluginFixtures.manifest()
        manifest.formatVersion = 99
        assertInvalid(manifest, .unsupportedVersion(99))
    }

    func testBlankFieldsAreRejected() {
        for blank in ["id", "name", "author", "version", "sdkVersion", "entryPoint"] {
            var manifest = PluginFixtures.manifest()
            switch blank {
            case "id": manifest.id = ""
            case "name": manifest.name = "  "
            case "author": manifest.author = ""
            case "version": manifest.version = "abc"
            case "sdkVersion": manifest.sdkVersion = "bogus"
            case "entryPoint": manifest.entryPoint = ""
            default: break
            }
            XCTAssertThrowsError(try manifest.validated(), "blank \(blank) must be rejected")
        }
    }

    func testIdentifierShape() {
        var manifest = PluginFixtures.manifest(id: "nodots")
        assertInvalid(manifest, .invalidManifest(""))
        manifest = PluginFixtures.manifest(id: "com.example..plugin")
        assertInvalid(manifest, .invalidManifest(""))
        manifest = PluginFixtures.manifest(id: "com.example/test")
        assertInvalid(manifest, .invalidManifest(""))
        try? PluginFixtures.manifest(id: "com.example.test-plugin").validated()
        try? PluginFixtures.manifest(id: "a1.b2").validated()
    }

    func testPermissionDeclarations() {
        var manifest = PluginFixtures.manifest(permissions: [
            .init(id: "local-map.read", required: true, reason: "a"),
            .init(id: "local-map.read", required: false, reason: "b"),
        ])
        assertInvalid(manifest, .invalidManifest(""))
        manifest = PluginFixtures.manifest(permissions: [.init(id: "has space", required: true, reason: "a")])
        assertInvalid(manifest, .invalidManifest(""))
    }

    func testEntryPointPathSafety() {
        for unsafe in ["/absolute.sh", "../escape.sh", "a/../../escape.sh", "resources/tool.sh", "manifest.json"] {
            var manifest = PluginFixtures.manifest(entryPoint: unsafe)
            manifest.entryPoint = unsafe
            XCTAssertThrowsError(try manifest.validated(), "\(unsafe) must be rejected")
        }
        try? PluginFixtures.manifest(entryPoint: "bin/run.sh").validated()
    }

    private func assertInvalid(_ manifest: PluginManifest, _ expected: PluginPackageError) {
        XCTAssertThrowsError(try manifest.validated()) { error in
            guard let packageError = error as? PluginPackageError else {
                return XCTFail("unexpected error type: \(error)")
            }
            switch (packageError, expected) {
            case (.unsupportedVersion, .unsupportedVersion),
                 (.invalidManifest, .invalidManifest):
                break
            default:
                XCTFail("expected \(expected), got \(packageError)")
            }
        }
    }
}
