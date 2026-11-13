import XCTest
@testable import PluginKit

@MainActor
final class PluginRunnerTests: XCTestCase {
    private func makeWorld() throws -> (PluginRunner, PluginRegistry, PermissionManager, URL) {
        let directory = makeTempDirectory()
        let registry = PluginRegistry(directory: directory.appendingPathComponent("plugins"))
        let store = PermissionStore(url: directory.appendingPathComponent("permissions.json"), secrets: InMemorySecrets())
        let manager = PermissionManager(registry: registry, store: store)
        return (PluginRunner(permissionManager: manager), registry, manager, directory)
    }

    private func installProbePlugin(
        _ registry: PluginRegistry, id: String, permissionID: String
    ) throws -> (InstalledPlugin, URL) {
        let script = PluginFixtures.permissionProbeScript(permissionID: permissionID)
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(id: id, permissions: [
                .init(id: permissionID, required: true, reason: "Probe."),
            ]), entryPointContents: script),
            to: registry.directory.appendingPathComponent("\(id)-\(UUID().uuidString).pxplugin")
        )
        let plugin = try registry.install(from: packageURL)
        let responseURL = registry.directory.appendingPathComponent("response-\(plugin.id)-\(UUID().uuidString).txt")
        return (plugin, responseURL)
    }

    func testPermissionRequestIsAnsweredWithTheUserDecision() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in true }
        let (plugin, responseURL) = try installProbePlugin(
            registry, id: "com.example.probe-grant", permissionID: "local-map.create"
        )
        defer { runner.stop(plugin.id) }

        try runner.start(plugin, registry: registry, arguments: [responseURL.path])
        let response = String(data: try await waitForFileAsync(responseURL), encoding: .utf8)
        XCTAssertTrue(response?.contains("permission.status") ?? false, response ?? "")
        XCTAssertTrue(response?.contains("GRANTED") ?? false, response ?? "")
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .granted)
    }

    func testDeniedRequestReturnsDeniedAndPromptsOnce() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        var prompts = 0
        manager.setConsentPresenter { _ in
            prompts += 1
            return false
        }
        let (plugin, responseURL) = try installProbePlugin(
            registry, id: "com.example.probe-deny", permissionID: "local-map.create"
        )
        defer { runner.stop(plugin.id) }

        try runner.start(plugin, registry: registry, arguments: [responseURL.path])
        let response = String(data: try await waitForFileAsync(responseURL), encoding: .utf8)
        XCTAssertTrue(response?.contains("DENIED") ?? false, response ?? "")
        XCTAssertEqual(prompts, 1)
    }

    func testRevokedDecisionIsReportedOnTheNextRun() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in true }
        let (plugin, responseURL) = try installProbePlugin(
            registry, id: "com.example.probe-revoke", permissionID: "local-map.create"
        )

        try runner.start(plugin, registry: registry, arguments: [responseURL.path])
        _ = try await waitForFileAsync(responseURL)
        _ = await waitUntilAsync(!runner.isRunning(plugin.id))
        try manager.revoke(pluginID: plugin.id, permissionID: "local-map.create")

        try FileManager.default.removeItem(at: responseURL)
        try runner.start(plugin, registry: registry, arguments: [responseURL.path])
        let response = String(data: try await waitForFileAsync(responseURL), encoding: .utf8)
        XCTAssertTrue(response?.contains("DENIED") ?? false, response ?? "")
    }

    func testMalformedLineTerminatesThePlugin() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in false }
        let script = """
        #!/bin/sh
        printf 'not json\\n'
        sleep 10
        """
        let packageURL = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(id: "com.example.probe-malformed", permissions: [
                .init(id: "local-map.read", required: true, reason: "Probe."),
            ]), entryPointContents: script),
            to: registry.directory.appendingPathComponent("malformed.pxplugin")
        )
        let plugin = try registry.install(from: packageURL)
        try runner.start(plugin, registry: registry)

        _ = await waitUntilAsync(!runner.isRunning(plugin.id))
        XCTAssertFalse(runner.isRunning(plugin.id))
        let exit = runner.lastExitDescription[plugin.id]
        XCTAssertTrue(exit?.contains("malformed") ?? false, exit ?? "")
    }

    func testAlreadyRunningAndMissingEntryPoint() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in true }
        // A plugin that stays alive long enough to observe the already-running guard.
        let sleeper = try PluginFixtures.makePackage(
            .init(manifest: PluginFixtures.manifest(id: "com.example.probe-state", permissions: [
                .init(id: "local-map.read", required: true, reason: "Probe."),
            ]), entryPointContents: "#!/bin/sh\nsleep 30\n"),
            to: registry.directory.appendingPathComponent("sleeper.pxplugin")
        )
        let plugin = try registry.install(from: sleeper)
        try runner.start(plugin, registry: registry)
        _ = await waitUntilAsync(runner.isRunning(plugin.id))
        XCTAssertThrowsError(try runner.start(plugin, registry: registry)) { error in
            XCTAssertEqual(error as? PluginRunner.PluginRunnerError, .alreadyRunning(plugin.id))
        }

        var broken = plugin
        // A different plugin id so the already-running guard does not fire first;
        // its install directory will not exist, so the entry point is missing.
        broken.manifest.id = "com.example.probe-state-broken"
        XCTAssertThrowsError(try runner.start(broken, registry: registry)) { error in
            guard case .entryPointMissing = error as? PluginRunner.PluginRunnerError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
        runner.stop(plugin.id)
    }
}
