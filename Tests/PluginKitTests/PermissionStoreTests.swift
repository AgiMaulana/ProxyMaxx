import XCTest
@testable import PluginKit

@MainActor
final class PermissionStoreTests: XCTestCase {
    func testReloadWithADifferentKeyFailsClosed() throws {
        // The decisions file is bound to the key that signed it: a store whose key
        // does not match must not read anything out of it.
        let directory = makeTempDirectory()
        let url = directory.appendingPathComponent("permissions.json")
        let writer = PermissionStore(url: url, secrets: InMemorySecrets())
        try writer.record(pluginID: "com.example.a", permissionID: "local-map.read", status: .granted)

        let reloaded = PermissionStore(url: url, secrets: InMemorySecrets())
        XCTAssertNotNil(reloaded.integrityError)
        XCTAssertEqual(reloaded.status(pluginID: "com.example.a", permissionID: "local-map.read"), .notRequested)
    }

    func testReloadWithTheSameKeyVerifiesAndKeepsTimestamps() throws {
        let directory = makeTempDirectory()
        let url = directory.appendingPathComponent("permissions.json")
        let secrets = InMemorySecrets()
        let first = PermissionStore(url: url, secrets: secrets)
        let decidedAt = Date(timeIntervalSince1970: 1_700_000_000)
        try first.record(pluginID: "com.example.a", permissionID: "local-map.read", status: .granted, decidedAt: decidedAt)

        let reloaded = PermissionStore(url: url, secrets: secrets)
        XCTAssertNil(reloaded.integrityError)
        XCTAssertEqual(reloaded.status(pluginID: "com.example.a", permissionID: "local-map.read"), .granted)
        XCTAssertEqual(reloaded.decision(pluginID: "com.example.a", permissionID: "local-map.read")?.decidedAt, decidedAt)
        XCTAssertEqual(reloaded.status(pluginID: "com.example.a", permissionID: "local-map.create"), .notRequested)
    }

    func testTamperedStateFailsClosed() throws {
        let directory = makeTempDirectory()
        let url = directory.appendingPathComponent("permissions.json")
        let secrets = InMemorySecrets()
        let store = PermissionStore(url: url, secrets: secrets)
        try store.record(pluginID: "com.example.a", permissionID: "local-map.read", status: .granted)

        var data = try Data(contentsOf: url)
        data[data.count - 10] ^= 0xFF
        try data.write(to: url)

        let tampered = PermissionStore(url: url, secrets: secrets)
        XCTAssertNotNil(tampered.integrityError)
        XCTAssertEqual(tampered.status(pluginID: "com.example.a", permissionID: "local-map.read"), .notRequested)
        XCTAssertFalse(tampered.isTrustworthy)
    }

    func testTheFileIsWritten0600() throws {
        let directory = makeTempDirectory()
        let url = directory.appendingPathComponent("permissions.json")
        let store = PermissionStore(url: url, secrets: InMemorySecrets())
        try store.record(pluginID: "p", permissionID: "local-map.read", status: .granted)
        let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
        XCTAssertEqual((attributes[.posixPermissions] as? NSNumber)?.int16Value, 0o600)
    }

    func testRemovingDecisionsForOnePluginLeavesOthers() throws {
        let url = makeTempDirectory().appendingPathComponent("permissions.json")
        let store = PermissionStore(url: url, secrets: InMemorySecrets())
        try store.record(pluginID: "com.example.a", permissionID: "local-map.read", status: .granted)
        try store.record(pluginID: "com.example.b", permissionID: "local-map.read", status: .granted)
        try store.removeDecisions(pluginID: "com.example.a")
        XCTAssertEqual(store.status(pluginID: "com.example.a", permissionID: "local-map.read"), .notRequested)
        XCTAssertEqual(store.status(pluginID: "com.example.b", permissionID: "local-map.read"), .granted)
    }

    func testIntegrityKeyIsReusedOrRegenerated() throws {
        let secrets = InMemorySecrets()
        let first = try PermissionStore.integrityKey(using: secrets)
        let second = try PermissionStore.integrityKey(using: secrets)
        XCTAssertEqual(first, second)
        XCTAssertEqual(first.count, 32)
    }
}
