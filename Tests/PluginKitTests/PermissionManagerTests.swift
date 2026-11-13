import XCTest
@testable import PluginKit

@MainActor
final class PermissionManagerTests: XCTestCase {
    private func makeManager(
        url: URL,
        consent: PermissionManager.ConsentPresenting? = nil
    ) -> (PermissionManager, PluginRegistry, PermissionStore) {
        let registry = PluginRegistry(directory: url.deletingLastPathComponent().appendingPathComponent("plugins"))
        let store = PermissionStore(url: url, secrets: InMemorySecrets())
        let manager = PermissionManager(registry: registry, store: store)
        manager.setConsentPresenter(consent)
        return (manager, registry, store)
    }

    private func installPlugin(_ registry: PluginRegistry, id: String, permissions: [PluginManifest.PermissionDeclaration]) throws -> InstalledPlugin {
        let directory = registry.directory
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(id: id, permissions: permissions), entryPointContents: "#!/bin/sh\ntrue\n"),
            to: directory.appendingPathComponent("\(id)-\(UUID().uuidString).pxplugin")
        )
        return try registry.install(from: packageURL)
    }

    func testAuthorizeMatrix() throws {
        let directory = makeTempDirectory()
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json"))

        // Unknown plugin id.
        XCTAssertThrowsError(try manager.authorize(pluginID: "com.example.ghost", permissionID: "local-map.create")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .unknownPlugin("com.example.ghost"))
        }

        let plugin = try installPlugin(registry, id: "com.example.a", permissions: [
            .init(id: "local-map.create", required: true, reason: "Make rules."),
            .init(id: "local-map.read", required: true, reason: "List rules."),
        ])

        // Declared but never requested.
        XCTAssertThrowsError(try manager.authorize(pluginID: plugin.id, permissionID: "local-map.create")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .notGranted("local-map.create"))
        }
        // Not declared by this plugin.
        XCTAssertThrowsError(try manager.authorize(pluginID: plugin.id, permissionID: "local-map.delete")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .notDeclared("local-map.delete"))
        }

        try manager.grant(pluginID: plugin.id, permissionID: "local-map.create")
        try manager.authorize(pluginID: plugin.id, permissionID: "local-map.create") // passes
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .granted)

        // Revocation applies to the very next authorize.
        try manager.revoke(pluginID: plugin.id, permissionID: "local-map.create")
        XCTAssertThrowsError(try manager.authorize(pluginID: plugin.id, permissionID: "local-map.create")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .notGranted("local-map.create"))
        }
    }

    func testGrantingUndeclaredOrUnknownPermissionsFails() throws {
        let directory = makeTempDirectory()
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json"))
        let plugin = try installPlugin(registry, id: "com.example.b", permissions: [
            .init(id: "local-map.read", required: true, reason: "List rules."),
        ])
        XCTAssertThrowsError(try manager.grant(pluginID: plugin.id, permissionID: "local-map.create")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .notDeclared("local-map.create"))
        }
        XCTAssertThrowsError(try manager.grant(pluginID: "com.example.ghost", permissionID: "local-map.read")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .unknownPlugin("com.example.ghost"))
        }
    }

    func testRequestShowsConsentOnceAndRecordsTheDecision() async throws {
        let directory = makeTempDirectory()
        var consentShown = 0
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json")) { request in
            consentShown += 1
            XCTAssertEqual(request.pluginName, "Test Plugin")
            XCTAssertEqual(request.permission.id, "local-map.create")
            XCTAssertTrue(request.required)
            return true
        }
        let plugin = try installPlugin(registry, id: "com.example.c", permissions: [
            .init(id: "local-map.create", required: true, reason: "Make rules."),
        ])

        let status = await manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        XCTAssertEqual(status, .granted)
        XCTAssertEqual(consentShown, 1)

        // A repeat request must not re-prompt (docs §7.3).
        let again = await manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        XCTAssertEqual(again, .granted)
        XCTAssertEqual(consentShown, 1)
    }

    func testDeniedPermissionIsNotReprompted() async throws {
        let directory = makeTempDirectory()
        var consentShown = 0
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json")) { _ in
            consentShown += 1
            return false
        }
        let plugin = try installPlugin(registry, id: "com.example.d", permissions: [
            .init(id: "local-map.create", required: false, reason: "Maybe make rules."),
        ])
        let status = await manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        XCTAssertEqual(status, .denied)
        let again = await manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        XCTAssertEqual(again, .denied)
        XCTAssertEqual(consentShown, 1)
        // And the host still refuses protected operations.
        XCTAssertThrowsError(try manager.authorize(pluginID: plugin.id, permissionID: "local-map.create"))
    }

    func testConcurrentRequestsCoalesceIntoOneConsent() async throws {
        let directory = makeTempDirectory()
        var consentShown = 0
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json")) { _ in
            consentShown += 1
            // A slow sheet, so both callers pile onto the same pending request.
            try? await Task.sleep(nanoseconds: 100_000_000)
            return true
        }
        let plugin = try installPlugin(registry, id: "com.example.e", permissions: [
            .init(id: "local-map.create", required: true, reason: "Make rules."),
        ])
        async let first = manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        async let second = manager.request(pluginID: plugin.id, permissionID: "local-map.create")
        let statuses = await [first, second]
        XCTAssertEqual(statuses, [.granted, .granted])
        XCTAssertEqual(consentShown, 1)
    }

    func testIntegrityFailureDeniesEverything() throws {
        let directory = makeTempDirectory()
        let url = directory.appendingPathComponent("permissions.json")
        let secrets = InMemorySecrets()
        let (manager, registry, store) = makeManager(url: url)
        let plugin = try? installPlugin(registry, id: "com.example.f", permissions: [
            .init(id: "local-map.create", required: true, reason: "Make rules."),
        ])
        try? manager.grant(pluginID: plugin!.id, permissionID: "local-map.create")

        var data = try Data(contentsOf: url)
        data[5] ^= 0xFF
        try data.write(to: url)
        // The manager observes the failure through its store.
        let brokenStore = PermissionStore(url: url, secrets: secrets)
        XCTAssertNotNil(brokenStore.integrityError)
        _ = brokenStore

        // The live store must re-check: simulate by loading the tampered file into
        // the same manager's backing store via a fresh PermissionManager.
        let reloaded = PermissionManager(registry: registry, store: PermissionStore(url: url, secrets: secrets))
        XCTAssertThrowsError(try reloaded.authorize(pluginID: plugin!.id, permissionID: "local-map.create")) { error in
            XCTAssertEqual(error as? PluginPermissionError, .integrityFailure)
        }
        _ = store
    }

    func testUninstallRemovesDecisions() throws {
        let directory = makeTempDirectory()
        let (manager, registry, _) = makeManager(url: directory.appendingPathComponent("permissions.json"))
        let plugin = try installPlugin(registry, id: "com.example.g", permissions: [
            .init(id: "local-map.read", required: true, reason: "List rules."),
        ])
        try manager.grant(pluginID: plugin.id, permissionID: "local-map.read")
        try manager.removeDecisions(pluginID: plugin.id)
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.read"), .notRequested)
    }
}
