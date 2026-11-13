import XCTest
import ZIPFoundation
@testable import PluginKit

/// End-to-end SDK ↔ host integration: installs a real `.pxplugin` whose entry
/// point is a Swift executable built on ProxyMaxxPluginSDK, spawns it through
/// PluginRunner speaking Protocol v1, and asserts observable outcomes through
/// the plugin's own result file and the host permission store.
///
/// The fixture plugin (Fixtures/SDKFixturePlugin) uses the SDK's default
/// `PermissionManager()`: manifest from PROXYMAXX_PLUGIN_DIR, JSON-lines
/// transport over stdin/stdout, local validation, fail-closed handling.
@MainActor
final class SDKIntegrationTests: XCTestCase {
    private func makeWorld() throws -> (PluginRunner, PluginRegistry, PermissionManager, URL) {
        let directory = makeTempDirectory()
        let registry = PluginRegistry(directory: directory.appendingPathComponent("plugins"))
        let store = PermissionStore(url: directory.appendingPathComponent("permissions.json"), secrets: InMemorySecrets())
        let manager = PermissionManager(registry: registry, store: store)
        return (PluginRunner(permissionManager: manager), registry, manager, directory)
    }

    /// Locates the SDKFixturePlugin binary built alongside this test run.
    private func fixtureBinaryURL() throws -> URL {
        let cwd = FileManager.default.currentDirectoryPath
        let buildRoot = URL(fileURLWithPath: cwd).appendingPathComponent(".build")
        guard FileManager.default.fileExists(atPath: buildRoot.path) else {
            XCTFail("Run via `swift test` so the fixture plugin is built: missing \(buildRoot.path)")
            throw NSError(domain: "SDKIntegration", code: 1)
        }
        if let enumerator = FileManager.default.enumerator(at: buildRoot, includingPropertiesForKeys: [.isRegularFileKey]) {
            for case let url as URL in enumerator where url.lastPathComponent == "SDKFixturePlugin" {
                var isDirectory: ObjCBool = false
                FileManager.default.fileExists(atPath: url.path, isDirectory: &isDirectory)
                if !isDirectory.boolValue, FileManager.default.isExecutableFile(atPath: url.path) {
                    return url
                }
            }
        }
        XCTFail("SDKFixturePlugin binary not found under \(buildRoot.path)")
        throw NSError(domain: "SDKIntegration", code: 2)
    }

    /// Builds and installs the SDK fixture plugin: manifest.json + the compiled
    /// SDKFixturePlugin binary as the entry point.
    @discardableResult
    private func installFixture(
        _ registry: PluginRegistry,
        id: String = "com.example.sdk-fixture",
        permissions: [PluginManifest.PermissionDeclaration] = [
            .init(id: "local-map.read", required: true, reason: "Read rules."),
            .init(id: "local-map.create", required: true, reason: "Create rules."),
        ]
    ) throws -> InstalledPlugin {
        let binary = try fixtureBinaryURL()
        let staging = registry.directory.appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let manifest = PluginFixtures.manifest(
            id: id,
            sdkVersion: "^1.0.0",
            permissions: permissions,
            entryPoint: "SDKFixturePlugin"
        )
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(manifest).write(to: staging.appendingPathComponent("manifest.json"))
        try FileManager.default.copyItem(at: binary, to: staging.appendingPathComponent("SDKFixturePlugin"))

        let packageURL = registry.directory.appendingPathComponent("\(id)-\(UUID().uuidString).pxplugin")
        let archive = try Archive(url: packageURL, accessMode: .create)
        try archive.addEntry(with: "manifest.json", relativeTo: staging)
        try archive.addEntry(with: "SDKFixturePlugin", relativeTo: staging)

        return try registry.install(from: packageURL)
    }

    private func runFixtureScenario(
        runner: PluginRunner, registry: PluginRegistry, plugin: InstalledPlugin,
        mode: String, expectedLines: Int
    ) async throws -> [String] {
        let resultURL = registry.directory.appendingPathComponent("result-\(mode)-\(UUID().uuidString).txt")
        try runner.start(plugin, registry: registry, arguments: [resultURL.path, mode])
        defer { runner.stop(plugin.id) }
        let data = try await waitForFileAsync(resultURL, timeout: 15)
        return String(data: data, encoding: .utf8)?
            .split(separator: "\n").map(String.init) ?? []
    }

    // MARK: - Scenarios

    func testRequestShowsConsentAndPersistsGrant() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in true }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "request", expectedLines: 1
        )

        XCTAssertEqual(lines, ["REQUEST=GRANTED"])
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .granted)
    }

    func testDeniedRequestReturnsDeniedAndPromptsOnce() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        var prompts = 0
        manager.setConsentPresenter { _ in
            prompts += 1
            return false
        }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "requestTwice", expectedLines: 1
        )

        XCTAssertEqual(lines, ["REQUEST=DENIED DENIED"], "second request must not re-prompt")
        XCTAssertEqual(prompts, 1)
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .denied)
    }

    func testCheckReportsCurrentStatusWithoutConsent() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in
            XCTFail("check must never trigger consent")
            return false
        }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "check", expectedLines: 1
        )

        XCTAssertEqual(lines, ["CHECK=NOT_REQUESTED"])
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .notRequested)
    }

    func testCheckAllReturnsEveryDeclaredPermission() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in
            XCTFail("checkAll must never trigger consent")
            return false
        }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "checkAll", expectedLines: 1
        )

        XCTAssertEqual(lines, ["CHECKALL=local-map.create=NOT_REQUESTED local-map.read=NOT_REQUESTED"])
    }

    func testUndeclaredPermissionFailsLocallyWithoutConsent() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        manager.setConsentPresenter { _ in
            XCTFail("undeclared request must never reach consent")
            return false
        }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "undeclared", expectedLines: 1
        )

        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasPrefix("UNDECLARED=NOT-DECLARED:filesystem.read"), lines[0])
    }

    func testPluginCancellationResolvesAsCancellationWithoutDecision() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        let consentStarted = expectation(description: "consent presented")
        manager.setConsentPresenter { request in
            consentStarted.fulfill()
            // Simulates the user thinking; the plugin cancels before answering.
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            return true
        }
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "cancel", expectedLines: 1
        )

        await fulfillment(of: [consentStarted], timeout: 5)
        XCTAssertEqual(lines, ["CANCEL=CANCELLED"])
        // Spec §7.2: cancellation must not surface as a status decision on the wire.
        // The host-side consent task keeps running (documented PR #49 gap: the
        // presenter resolution still persists), which the follow-up host change
        // must fix alongside grouped consent.
    }

    func testBatchRequestReturnsIndependentDecisions() async throws {
        let (runner, registry, manager, _) = try makeWorld()
        var decisions: [String: Bool] = [:]
        manager.setConsentPresenter { request in
            // Independent per-permission decisions within one batch experience.
            decisions[request.permission.id] ?? true
        }
        decisions = ["local-map.read": true, "local-map.create": false]
        let plugin = try installFixture(registry)

        let lines = try await runFixtureScenario(
            runner: runner, registry: registry, plugin: plugin, mode: "requestAll", expectedLines: 1
        )

        XCTAssertEqual(lines, ["REQUESTALL=local-map.read=GRANTED local-map.create=DENIED"])
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.read"), .granted)
        XCTAssertEqual(manager.status(pluginID: plugin.id, permissionID: "local-map.create"), .denied)
    }
}
