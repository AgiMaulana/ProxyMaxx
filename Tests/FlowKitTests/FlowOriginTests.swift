import XCTest
@testable import FlowKit

/// Covers how a flow is called local or remote from its peer address, and how the sidebar's
/// device choice narrows the table.
final class FlowOriginTests: XCTestCase {
    func testLoopbackPeersAreLocalTraffic() {
        for address in ["127.0.0.1:52344", "::1:52344", "[::1]:52344", "::ffff:127.0.0.1:52344", "localhost:9000"] {
            XCTAssertEqual(flow(address: address).origin, .local, address)
        }
    }

    func testAnyOtherPeerIsRemoteTraffic() {
        // The Android emulator's host alias, and a phone on the same Wi-Fi.
        for address in ["10.0.2.2:51000", "192.168.1.20:44311"] {
            XCTAssertEqual(flow(address: address).origin, .remoteDevice, address)
        }
        XCTAssertEqual(flow(address: nil).origin, .local)
        XCTAssertEqual(flow(address: "no-port").origin, .local)
    }

    /// The emulator reaches the proxy through qemu's `netsimd`, which shows up as a loopback
    /// peer. Its traffic came from the device, so it must not be reported as a Mac app.
    func testEmulatorForwarderTrafficIsRemoteEvenFromLoopback() {
        let forwarder = ClientApp(name: "netsimd", path: "/opt/homebrew/bin/netsimd", pid: 41463)
        let emulator = flow(address: "127.0.0.1:52542", clientApp: forwarder)
        XCTAssertEqual(emulator.origin, .remoteDevice)

        // An ordinary Mac process on loopback stays local.
        let macProcess = ClientApp(name: "curl", path: "/usr/bin/curl", pid: 100)
        XCTAssertEqual(flow(address: "127.0.0.1:52027", clientApp: macProcess).origin, .local)
        XCTAssertEqual(flow(address: "127.0.0.1:52027").origin, .local)
    }

    func testRemotePeerKeepsIPv6BracketsFromLeakingIntoTheIP() {
        XCTAssertEqual(Flow.remotePeer(of: "10.0.2.2:51000"), "10.0.2.2")
        XCTAssertEqual(Flow.remotePeer(of: "[::1]:51000"), "::1")
        XCTAssertEqual(Flow.remotePeer(of: "::1:51000"), "::1")
        XCTAssertNil(Flow.remotePeer(of: "10.0.2.2"))
    }

    /// A device is chosen by serial, and only once the engine has labelled the flow with it.
    func testDeviceSelectionIsExactAndUnlabelledFlowsAreExcluded() {
        let device = ConnectedDevice(serial: "emulator-5554", name: "Pixel (emulator-5554)", address: "10.0.2.2")
        let emulator = flow(address: "10.0.2.2:51000")
        let otherEmulator = flow(address: "10.0.2.2:52000")
        let fromMac = flow(address: "127.0.0.1:53000")
        DeviceAttribution.reset()
        defer { DeviceAttribution.reset() }
        DeviceAttribution.record(device, for: emulator.id)
        DeviceAttribution.record(
            ConnectedDevice(serial: "emulator-5556", name: "Other (emulator-5556)", address: "10.0.2.2"),
            for: otherEmulator.id
        )

        let filter = FlowFilter(sidebarSelection: .device("emulator-5554"))
        XCTAssertEqual(filter.apply(to: [emulator, otherEmulator, fromMac]).map(\.id), [emulator.id])
        XCTAssertTrue(FlowFilter().matches(fromMac))
        XCTAssertFalse(FlowFilter(sidebarSelection: .device("emulator-5554")).matches(fromMac))
    }

    func testDeviceChoiceIntersectsTextAndMethodFilters() {
        let device = ConnectedDevice(serial: "emulator-5554", name: "Pixel (emulator-5554)", address: "10.0.2.2")
        let flow = flow(address: "10.0.2.2:51000")
        DeviceAttribution.reset()
        defer { DeviceAttribution.reset() }
        DeviceAttribution.record(device, for: flow.id)

        var filter = FlowFilter(method: "POST", sidebarSelection: .device("emulator-5554"))
        XCTAssertFalse(filter.matches(flow))
        filter.method = "GET"
        XCTAssertTrue(filter.matches(flow))
        filter.method = "All"
        filter.text = "missing.test"
        XCTAssertFalse(filter.matches(flow))
        filter.text = "example.test"
        XCTAssertTrue(filter.matches(flow))
    }

    func testAttributionMapDropsOldFlowsInsteadOfGrowingForever() {
        let device = ConnectedDevice(serial: "emulator-5554", name: "Pixel (emulator-5554)", address: "10.0.2.2")
        DeviceAttribution.reset()
        defer { DeviceAttribution.reset() }
        let ids = (0..<50_010).map { _ in UUID() }
        for id in ids { DeviceAttribution.record(device, for: id) }
        XCTAssertNil(DeviceAttribution.connectedDevice(id: ids[0]))
        XCTAssertNotNil(DeviceAttribution.connectedDevice(id: ids[ids.count - 1]))
    }

    private func flow(address: String?, clientApp: ClientApp? = nil) -> Flow {
        Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.test", port: 80, path: "/capture"),
            clientApp: clientApp,
            clientAddress: address
        )
    }
}
