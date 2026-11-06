import XCTest
import Darwin
@testable import SystemKit

/// Covers the evidence used to call an emulator "connected": adb's listing plus a live
/// console port, which is what separates a running emulator from an entry adb remembers.
final class ConnectedDeviceTests: XCTestCase {
    func testConsolePortComesFromTheSerial() {
        XCTAssertEqual(AndroidToolchain.consolePort(forSerial: "emulator-5554"), 5554)
        XCTAssertEqual(AndroidToolchain.consolePort(forSerial: "emulator-5556"), 5556)
        // Odd serials are rounded down to the even console port they belong to.
        XCTAssertEqual(AndroidToolchain.consolePort(forSerial: "emulator-5555"), 5554)
        XCTAssertNil(AndroidToolchain.consolePort(forSerial: "R58M12ABCDE"))
        XCTAssertNil(AndroidToolchain.consolePort(forSerial: "emulator-"))
        XCTAssertNil(AndroidToolchain.consolePort(forSerial: "emulator-0"))
        XCTAssertNil(AndroidToolchain.consolePort(forSerial: "emulator-abc"))
    }

    func testOnlyAnEmulatorHostAddressCountsAsEmulatorTraffic() {
        XCTAssertTrue(AndroidToolchain.isEmulatorAddress("10.0.2.2"))
        XCTAssertFalse(AndroidToolchain.isEmulatorAddress("192.168.1.20"))
        XCTAssertFalse(AndroidToolchain.isEmulatorAddress("127.0.0.1"))
    }

    /// A port with nothing behind it must read as not listening; a port we bound ourselves
    /// must read as listening. Both use the same socket check the sidebar relies on.
    func testLivenessFollowsTheSocketRatherThanTheListing() throws {
        let listener = try XCTUnwrap(ListeningSocket())
        XCTAssertTrue(AndroidToolchain.isListeningOnLoopback(port: listener.port))
        // Nothing is bound while the probe runs, so the same check has to say so on a
        // fresh port from the same allocator.
        let closed = try XCTUnwrap(ListeningSocket())
        let closedPort = closed.port
        closed.close()
        XCTAssertFalse(AndroidToolchain.isListeningOnLoopback(port: closedPort))
    }
}

/// A loopback listener that accepts one connection, so a connect() succeeds against it.
private final class ListeningSocket {
    let descriptor: Int32
    let port: Int

    init?() {
        let socket = socket(AF_INET, SOCK_STREAM, 0)
        guard socket >= 0 else { return nil }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_port = 0
        address.sin_addr.s_addr = inet_addr("127.0.0.1")
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        let bound = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(socket, $0, length)
            }
        }
        guard bound == 0, listen(socket, 4) == 0 else { Darwin.close(socket); return nil }
        var local = sockaddr_in()
        _ = withUnsafeMutablePointer(to: &local) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(socket, $0, &length)
            }
        }
        descriptor = socket
        port = Int(UInt16(bigEndian: local.sin_port))
    }

    deinit { Darwin.close(descriptor) }

    func close() { Darwin.close(descriptor) }
}
