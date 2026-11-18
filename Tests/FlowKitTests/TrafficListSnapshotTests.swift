import XCTest
@testable import FlowKit

@MainActor
final class TrafficListSnapshotTests: XCTestCase {
    private func makeFlow(
        url: String,
        method: String = "GET",
        host: String = "example.com",
        clientApp: ClientApp? = nil,
        device: ConnectedDevice? = nil,
        isPinned: Bool = false
    ) -> Flow {
        let uri = URL(string: url)!
        let scheme = uri.scheme ?? "https"
        let reqHost = uri.host ?? host
        let port = uri.port ?? (scheme == "https" ? 443 : 80)
        let path = uri.path.isEmpty ? "/" : uri.path

        let req = HTTPRequest(
            method: method,
            scheme: scheme,
            host: reqHost,
            port: port,
            path: path,
            httpVersion: "HTTP/1.1",
            headers: HTTPHeaders(),
            body: Data()
        )
        let res = HTTPResponse(
            statusCode: 200,
            httpVersion: "HTTP/1.1",
            headers: HTTPHeaders(),
            body: Data()
        )
        let flow = Flow(
            id: UUID(),
            request: req,
            response: res,
            clientApp: clientApp,
            isPinned: isPinned
        )
        if let device {
            DeviceAttribution.record(device, for: flow.id)
        }
        return flow
    }

    func testSinglePassSnapshotComputesSummaryAndCounts() {
        let app1 = ClientApp(name: "Safari", bundleIdentifier: "com.apple.Safari", pid: 100)
        let app2 = ClientApp(name: "Chrome", bundleIdentifier: "com.google.Chrome", pid: 200)
        let dev1 = ConnectedDevice(serial: "emulator-5554", name: "Pixel 9", address: "127.0.0.1", isEmulator: true)

        let flow1 = makeFlow(url: "https://api.github.com/user", host: "api.github.com", clientApp: app1)
        let flow2 = makeFlow(url: "https://example.com/index", host: "example.com", clientApp: app2)
        let flow3 = makeFlow(url: "https://example.com/api", host: "example.com", device: dev1)

        let flows = [flow1, flow2, flow3]
        let pinEntity = SidebarEntity.domain("api.github.com")
        let saveEntity = SidebarEntity.device(serial: "emulator-5554", label: "Pixel 9")

        let snapshot = TrafficListSnapshot.compute(
            flows: flows,
            filter: FlowFilter(),
            navigation: SidebarNavigation(),
            pinned: [pinEntity],
            saved: [saveEntity],
            deviceSerials: ["emulator-5554"]
        )

        // Summary counts
        XCTAssertEqual(snapshot.summary.total, 3)
        XCTAssertEqual(snapshot.summary.domains, ["api.github.com", "example.com"])
        XCTAssertEqual(snapshot.summary.domainCount("example.com"), 2)
        XCTAssertEqual(snapshot.summary.domainCount("api.github.com"), 1)

        // Device counts
        XCTAssertEqual(snapshot.count(for: "emulator-5554"), 1)
        XCTAssertEqual(snapshot.count(for: "unknown-device"), 0)

        // Mark counts
        XCTAssertEqual(snapshot.count(for: pinEntity), 1)
        XCTAssertEqual(snapshot.count(for: saveEntity), 1)

        // Pinned and saved subsets
        XCTAssertEqual(snapshot.pinnedFlows.count, 1)
        XCTAssertEqual(snapshot.pinnedFlows.first?.id, flow1.id)
        XCTAssertEqual(snapshot.savedFlows.count, 1)
        XCTAssertEqual(snapshot.savedFlows.first?.id, flow3.id)

        // Filtered flows matching All
        XCTAssertEqual(snapshot.flows.count, 3)
    }

    func testPinnedAndSavedCollectionsFilterRows() {
        let pinEntity = SidebarEntity.domain("pinned.com")
        let flowPinned = makeFlow(url: "https://pinned.com/a", host: "pinned.com")
        let flowOther = makeFlow(url: "https://other.com/b", host: "other.com")

        let flows = [flowPinned, flowOther]

        // Pinned collection
        let pinnedNav = SidebarNavigation(collection: .pinned)
        let pinnedSnapshot = TrafficListSnapshot.compute(
            flows: flows,
            filter: FlowFilter(),
            navigation: pinnedNav,
            pinned: [pinEntity],
            saved: []
        )
        XCTAssertEqual(pinnedSnapshot.flows.count, 1)
        XCTAssertEqual(pinnedSnapshot.flows.first?.id, flowPinned.id)

        // Saved collection with no saved marks
        let savedNav = SidebarNavigation(collection: .saved)
        let savedSnapshot = TrafficListSnapshot.compute(
            flows: flows,
            filter: FlowFilter(),
            navigation: savedNav,
            pinned: [pinEntity],
            saved: []
        )
        XCTAssertEqual(savedSnapshot.flows.count, 0)
    }

    func testCoordinatorSynchronousExecutionBelowThreshold() {
        let coordinator = TrafficListCoordinator(threshold: 1.0) // 1 second threshold = fast synchronous path

        let flow = makeFlow(url: "https://test.com/one")
        coordinator.updateIfNeeded(
            flows: [flow],
            revision: 1,
            filter: FlowFilter(),
            navigation: SidebarNavigation(),
            pinned: [],
            saved: [],
            deviceSerials: []
        )

        XCTAssertEqual(coordinator.snapshot.flows.count, 1)
        XCTAssertEqual(coordinator.generation, 1)
    }

    func testCoordinatorDetachedExecutionAboveThreshold() async {
        let coordinator = TrafficListCoordinator(threshold: 0.0) // 0s threshold forces detached execution

        let flow = makeFlow(url: "https://detached.com/data")
        coordinator.updateIfNeeded(
            flows: [flow],
            revision: 1,
            filter: FlowFilter(),
            navigation: SidebarNavigation(),
            pinned: [],
            saved: [],
            deviceSerials: []
        )

        XCTAssertEqual(coordinator.generation, 1)

        // Wait briefly for detached task to finish and publish on MainActor
        try? await Task.sleep(nanoseconds: 50_000_000) // 50ms

        XCTAssertEqual(coordinator.snapshot.flows.count, 1)
        XCTAssertEqual(coordinator.snapshot.flows.first?.url, "https://detached.com/data")
    }

    func testCoordinatorDiscardsStaleResultWhenSuperseded() async {
        let coordinator = TrafficListCoordinator(threshold: 0.0) // Detached execution

        let flow1 = makeFlow(url: "https://first.com/a")
        let flow2 = makeFlow(url: "https://second.com/b")

        // First update
        coordinator.updateIfNeeded(
            flows: [flow1],
            revision: 1,
            filter: FlowFilter(),
            navigation: SidebarNavigation(),
            pinned: [],
            saved: [],
            deviceSerials: []
        )
        XCTAssertEqual(coordinator.generation, 1)

        // Immediately supersede with second update
        coordinator.updateIfNeeded(
            flows: [flow2],
            revision: 2,
            filter: FlowFilter(),
            navigation: SidebarNavigation(),
            pinned: [],
            saved: [],
            deviceSerials: []
        )
        XCTAssertEqual(coordinator.generation, 2)

        try? await Task.sleep(nanoseconds: 80_000_000)

        // The snapshot must reflect the latest generation (flow2), discarding flow1
        XCTAssertEqual(coordinator.snapshot.flows.count, 1)
        XCTAssertEqual(coordinator.snapshot.flows.first?.url, "https://second.com/b")
    }
}
