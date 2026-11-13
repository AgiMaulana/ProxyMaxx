import XCTest
@testable import RuleKit

/// The Local Override authorization gate: plugin callers must pass it, internal
/// callers never touch it, and an unplugged gate denies plugin traffic (fail closed).
@MainActor
final class LocalMapGateTests: XCTestCase {
    func testPluginCallerIsGated() throws {
        let store = RuleStore()
        var seenOperations: [LocalMapOperation] = []
        store.localMapAuthorizationGate = { pluginID, operation in
            XCTAssertEqual(pluginID, "com.example.plugin")
            seenOperations.append(operation)
            throw PluginPermissionDenialStub()
        }
        XCTAssertThrowsError(try store.addMapLocalRule(MapLocalRule(url: "a/*"), callerPluginID: "com.example.plugin"))
        XCTAssertEqual(store.mapLocalRules.count, 0)
        XCTAssertEqual(seenOperations, [.create])
    }

    func testInternalCallerIsNeverGated() throws {
        let store = RuleStore()
        var gateCalls = 0
        store.localMapAuthorizationGate = { _, _ in gateCalls += 1 }
        try store.addMapLocalRule(MapLocalRule(url: "a/*"))
        try store.updateMapLocalRule(MapLocalRule(name: "one", url: "a/*", matchStyle: .contains))
        try store.moveMapLocalRule(id: store.mapLocalRules[0].id, by: 0)
        XCTAssertEqual(store.mapLocalRules.count, 1)
        XCTAssertEqual(gateCalls, 0)
    }

    func testMissingGateDeniesPluginCallers() {
        let store = RuleStore()
        XCTAssertThrowsError(try store.addMapLocalRule(MapLocalRule(url: "a/*"), callerPluginID: "com.example.plugin"))
        // The currentRuleFile read path is gated too.
        XCTAssertThrowsError(try store.currentRuleFile(callerPluginID: "com.example.plugin"))
        // ...while internal callers read freely.
        XCTAssertNoThrow(try store.currentRuleFile())
    }

    func testOperationMapping() throws {
        let store = RuleStore()
        var seen: [LocalMapOperation] = []
        store.localMapAuthorizationGate = { _, operation in seen.append(operation) }
        let rule = MapLocalRule(url: "a/*")
        try store.addMapLocalRule(rule, callerPluginID: "p")
        try store.updateMapLocalRule(rule, callerPluginID: "p")
        try store.setMapLocalRule(id: rule.id, enabled: false, callerPluginID: "p")
        try store.removeMapLocalRules(ids: [rule.id], callerPluginID: "p")
        XCTAssertEqual(seen, [.create, .update, .update, .delete])
    }

    func testBundleOperationsMapAcrossTheBoundary() throws {
        let store = RuleStore()
        var seen: [LocalMapOperation] = []
        store.localMapAuthorizationGate = { _, operation in seen.append(operation) }
        // Bundle export is a read; a missing bundle fails before or after the gate
        // but the gate call itself is what this test observes.
        XCTAssertThrowsError(try store.exportMapLocalBundle(id: UUID(), to: URL(fileURLWithPath: "/tmp/x.zip"), callerPluginID: "p"))
        XCTAssertTrue(seen.contains(.read))
    }
}

/// A stand-in denial so the gate's contract, not a specific error type, is what the
/// test observes.
private struct PluginPermissionDenialStub: Error {}
