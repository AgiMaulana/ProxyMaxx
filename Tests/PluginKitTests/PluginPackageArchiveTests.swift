import XCTest
@testable import PluginKit

@MainActor
final class PluginPackageArchiveTests: XCTestCase {
    func testInspectReturnsTheManifest() throws {
        let directory = makeTempDirectory()
        let manifest = PluginFixtures.manifest(
            permissions: [
                .init(id: "local-map.read", required: true, reason: "Read rules."),
                .init(id: "local-map.delete", required: false, reason: "Tidy up."),
            ]
        )
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: "#!/bin/sh\ntrue\n",
                  resources: ["payload.txt": "hello"]),
            to: directory.appendingPathComponent("plugin.pxplugin")
        )
        let inspected = try PluginPackageArchive.inspect(packageURL)
        XCTAssertEqual(inspected, manifest)
    }

    func testInstallExtractsAndMakesTheEntryPointExecutable() throws {
        let directory = makeTempDirectory()
        let registry = PluginRegistry(directory: directory)
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n",
                  resources: ["payload.txt": "hello"]),
            to: directory.appendingPathComponent("plugin.pxplugin")
        )
        let plugin = try registry.install(from: packageURL)
        let entryPoint = registry.entryPointURL(for: plugin)
        XCTAssertEqual(try FileManager.default.attributesOfItem(atPath: entryPoint.path)[.posixPermissions] as? Int, 0o755)
        let payload = registry.installationDirectory(for: plugin.id).appendingPathComponent("resources/payload.txt")
        XCTAssertEqual(try String(contentsOf: payload, encoding: .utf8), "hello")
    }

    func testDuplicatePluginIDIsRejected() throws {
        let directory = makeTempDirectory()
        let registry = PluginRegistry(directory: directory)
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("plugin.pxplugin")
        )
        try registry.install(from: packageURL)
        XCTAssertThrowsError(try registry.install(from: packageURL)) { error in
            XCTAssertEqual(error as? PluginPackageError, .collision("Plugin 'com.example.test-plugin' is already installed."))
        }
    }

    func testMissingEntryPointIsRejected() throws {
        let directory = makeTempDirectory()
        let manifest = PluginFixtures.manifest()
        let stripped = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: nil, resources: [:]),
            to: directory.appendingPathComponent("stripped.pxplugin")
        )
        XCTAssertThrowsError(try PluginPackageArchive.inspect(stripped)) { error in
            guard case .invalidManifest(let message) = error as? PluginPackageError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("entrypoint.sh"), message)
        }
    }

    func testUnknownPermissionIsRejectedAtThePackageLevel() throws {
        let directory = makeTempDirectory()
        let manifest = PluginFixtures.manifest(permissions: [
            .init(id: "filesystem.read", required: true, reason: "Not in the registry."),
        ])
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("unknown-permission.pxplugin")
        )
        XCTAssertThrowsError(try PluginPackageArchive.inspect(packageURL)) { error in
            guard case .invalidManifest(let message) = error as? PluginPackageError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("filesystem.read"), message)
        }
    }

    func testIncompatibleSDKVersionIsRejected() throws {
        let directory = makeTempDirectory()
        let futureMajor = Int(PluginSDK.version.split(separator: ".").first!)! + 1
        let manifest = PluginFixtures.manifest(sdkVersion: "^\(futureMajor).0.0")
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("future.pxplugin")
        )
        XCTAssertThrowsError(try PluginPackageArchive.inspect(packageURL)) { error in
            guard case .invalidManifest(let message) = error as? PluginPackageError else {
                return XCTFail("unexpected error: \(error)")
            }
            XCTAssertTrue(message.contains("SDK"), message)
        }
    }

    func testTamperedArchiveIsRejected() throws {
        let directory = makeTempDirectory()
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("tampered.pxplugin")
        )
        var data = try Data(contentsOf: packageURL)
        // Flip one byte inside the central directory; the structural walk must refuse.
        data[data.count - 40] ^= 0xFF
        try data.write(to: packageURL)
        XCTAssertThrowsError(try PluginPackageArchive.inspect(packageURL))
    }

    func testTruncatedArchiveIsRejected() throws {
        let directory = makeTempDirectory()
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("truncated.pxplugin")
        )
        var data = try Data(contentsOf: packageURL)
        data.removeLast(30)
        try data.write(to: packageURL)
        XCTAssertThrowsError(try PluginPackageArchive.inspect(packageURL))
    }

    func testUnexpectedEntryIsRejected() throws {
        let directory = makeTempDirectory()
        let manifest = PluginFixtures.manifest()
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("base.pxplugin")
        )
        // Add a stray file outside the allowlist by rewriting the archive manually.
        let stray = directory.appendingPathComponent("stray")
        try FileManager.default.createDirectory(at: stray, withIntermediateDirectories: true)
        try "nope".write(to: stray.appendingPathComponent("smuggled.txt"), atomically: true, encoding: .utf8)
        let rewritten = try PluginFixtures.makePackage(
            .init(manifest: manifest, entryPointContents: "#!/bin/sh\ntrue\n", resources: ["../smuggled.txt": "nope"]),
            to: directory.appendingPathComponent("stray.pxplugin")
        )
        XCTAssertThrowsError(try PluginPackageArchive.inspect(rewritten))
        _ = stray
        _ = packageURL
    }
}

@MainActor
final class PluginRegistryTests: XCTestCase {
    func testInstallUninstallLifecycle() throws {
        let directory = makeTempDirectory()
        let registry = PluginRegistry(directory: directory)
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("plugin.pxplugin")
        )
        let plugin = try registry.install(from: packageURL)
        XCTAssertEqual(registry.installedPlugins.map(\.id), [plugin.id])
        XCTAssertTrue(FileManager.default.fileExists(atPath: registry.installationDirectory(for: plugin.id).path))

        try registry.uninstall(id: plugin.id)
        XCTAssertTrue(registry.installedPlugins.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: registry.installationDirectory(for: plugin.id).path))
    }

    func testRegistrationSurvivesAReload() throws {
        let directory = makeTempDirectory()
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("plugin.pxplugin")
        )
        let first = PluginRegistry(directory: directory)
        let plugin = try first.install(from: packageURL)
        let reloaded = PluginRegistry(directory: directory)
        // Date precision through JSON round-tripping can differ in sub-seconds, so
        // compare what the contract promises: the registration is restored.
        XCTAssertEqual(reloaded.installedPlugins.map(\.id), first.installedPlugins.map(\.id))
        XCTAssertEqual(reloaded.plugin(id: plugin.id)?.manifest, plugin.manifest)
    }

    func testUninstallingAnUnknownPluginThrows() {
        let registry = PluginRegistry(directory: makeTempDirectory())
        XCTAssertThrowsError(try registry.uninstall(id: "com.example.ghost")) { error in
            XCTAssertEqual(error as? PluginRegistryError, .unknownPlugin("com.example.ghost"))
        }
    }
}
