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
