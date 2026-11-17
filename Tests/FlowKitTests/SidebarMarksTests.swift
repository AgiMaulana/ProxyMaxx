import XCTest
@testable import FlowKit

/// Covers the sidebar's pinned/saved marks: identity, flow ownership, and persistence.
final class SidebarMarksTests: XCTestCase {
    @MainActor
    func testTogglingAddsThenRemovesByEntity() {
        let marks = SidebarMarks()
        let host = SidebarEntity.domain("api.example.test")
        XCTAssertFalse(marks.isPinned(host))
        marks.togglePin(host)
        XCTAssertTrue(marks.isPinned(host))
        XCTAssertEqual(marks.pinned, [host])
        marks.togglePin(host)
        XCTAssertTrue(marks.pinned.isEmpty)
    }

    /// A label that changed between runs must not turn one entry into two.
    func testIdentityIgnoresALabelChange() {
        let first = SidebarEntity(kind: .app, key: "bundle:test.app", label: "Old Name")
        let renamed = SidebarEntity(kind: .app, key: "bundle:test.app", label: "New Name")
        XCTAssertEqual(first, renamed)
        XCTAssertEqual(first.hashValue, renamed.hashValue)
        XCTAssertTrue(Set([first]).contains(renamed))
    }

    @MainActor
    func testMarksOwnTheFlowsOfTheirDeviceAppAndHost() {
        let marks = SidebarMarks()
        let device = ConnectedDevice(serial: "emulator-5554", name: "Pixel (emulator-5554)", address: "10.0.2.2")
        DeviceAttribution.reset()
        defer { DeviceAttribution.reset() }

        marks.togglePin(.domain("example.test"))
        XCTAssertTrue(marks.isPinned(flow()))
        XCTAssertFalse(marks.isSaved(flow()))

        let browser = ClientApp(name: "Browser", bundleIdentifier: "test.browser")
        marks.toggleSave(.app(browser))
        XCTAssertTrue(marks.isSaved(flow(client: browser)))
        XCTAssertFalse(marks.isSaved(flow(client: ClientApp(name: "Other"))))

        let emulator = flow(address: "10.0.2.2:51000")
        DeviceAttribution.record(device, for: emulator.id)
        marks.togglePin(.device(serial: "emulator-5554", label: "stale label"))
        XCTAssertTrue(marks.isPinned(emulator))
    }

    @MainActor
    func testMarksRoundTripThroughDisk() {
        let url = temporaryMarksFile()
        let marks = SidebarMarks(persistenceURL: url)
        marks.togglePin(.domain("api.example.test"))
        marks.toggleSave(.app(ClientApp(name: "Browser", bundleIdentifier: "test.browser")))
        marks.flushToDisk()

        let reloaded = SidebarMarks(persistenceURL: url)
        XCTAssertEqual(reloaded.pinned.map(\.key), ["api.example.test"])
        XCTAssertEqual(reloaded.saved.map(\.key), ["bundle:test.browser"])
        XCTAssertEqual(reloaded.saved.first?.label, "Browser")
    }

    @MainActor
    func testInMemoryStoreHoldsMarksWithoutAFile() {
        let marks = SidebarMarks()
        marks.togglePin(.domain("api.example.test"))
        XCTAssertEqual(marks.currentMarksFile().pinned.map(\.key), ["api.example.test"])
    }

    // MARK: - Collections navigation

    /// The reported bug: opening Pinned or Saved and clicking an entry dropped the app back
    /// to the All collection with nothing selected. The entry click must keep the collection.
    func testSelectingAnEntryKeepsItsCollectionOpen() {
        for collection in [SidebarSelection.pinned, .saved] {
            var navigation = SidebarNavigation()
            navigation.select(collection)
            XCTAssertEqual(navigation.collection, collection)
            XCTAssertNil(navigation.scope)

            navigation.select(.domain("api.example.test"))
            XCTAssertEqual(navigation.collection, collection, "entry click must not leave \(collection)")
            XCTAssertEqual(navigation.scope, .domain("api.example.test"))
            XCTAssertEqual(navigation.highlighted, .domain("api.example.test"))
        }
    }

    /// A collection row is not a flow predicate: Pinned and Saved narrow by marks instead,
    /// so `flowScope` must not hand `.pinned` to `FlowFilter` (which tests `flow.isPinned`).
    func testCollectionContributesNoFlowPredicate() {
        var navigation = SidebarNavigation()
        navigation.select(.pinned)
        XCTAssertEqual(navigation.flowScope, .all)

        navigation.select(.saved)
        XCTAssertEqual(navigation.flowScope, .all)

        navigation.select(.all)
        XCTAssertEqual(navigation.flowScope, .all)
    }

    /// Switching collection is a fresh start: a drill-down from the previous collection
    /// would otherwise silently narrow the new one.
    func testSwitchingCollectionDropsTheScope() {
        var navigation = SidebarNavigation()
        navigation.select(.pinned)
        navigation.select(.domain("api.example.test"))
        XCTAssertEqual(navigation.scope, .domain("api.example.test"))

        navigation.select(.saved)
        XCTAssertEqual(navigation.collection, .saved)
        XCTAssertNil(navigation.scope)
        XCTAssertEqual(navigation.highlighted, .saved)
    }

    /// An entry inside All narrows All, and highlights the entry rather than the row.
    func testEntryInsideAllNarrowsAll() {
        var navigation = SidebarNavigation()
        navigation.select(.client("bundle:test.app"))
        XCTAssertEqual(navigation.collection, .all)
        XCTAssertEqual(navigation.flowScope, .client("bundle:test.app"))
        XCTAssertEqual(navigation.highlighted, .client("bundle:test.app"))

        navigation.clearScope()
        XCTAssertEqual(navigation.highlighted, .all)
        XCTAssertEqual(navigation.flowScope, .all)
    }

    private func flow(address: String? = nil, client: ClientApp? = nil) -> Flow {
        Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.test", port: 80, path: "/capture"),
            clientApp: client,
            clientAddress: address
        )
    }

    private func temporaryMarksFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("sidebarmarks-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("sidebar-marks.json")
    }
}
