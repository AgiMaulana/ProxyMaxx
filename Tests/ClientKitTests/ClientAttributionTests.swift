import XCTest
import Darwin
import Foundation
import NIOCore
import NIOPosix
import FlowKit
@testable import ClientKit

final class ClientAttributionTests: XCTestCase {
    func testIPv4SocketOwnerAndMappedAddresses() throws {
        try withConnection(host: "127.0.0.1") { _, client, proxy in
            let scanner = ClientSocketScanner()
            XCTAssertEqual(owner(scanner, client: client, proxy: proxy), getpid())
            XCTAssertEqual(scanner.pid(
                clientAddress: "::ffff:127.0.0.1", clientPort: client.port!,
                proxyAddress: "::ffff:127.0.0.1", proxyPort: proxy.port!
            ), getpid())
        }
    }

    func testIPv6SocketOwner() throws {
        try withConnection(host: "::1") { _, client, proxy in
            XCTAssertEqual(owner(ClientSocketScanner(), client: client, proxy: proxy), getpid())
        }
    }

    func testMatchingPortsWithDifferentAddressesHaveNoLocalOwner() throws {
        for host in ["127.0.0.1", "::1"] {
            try withConnection(host: host) { _, client, proxy in
                let scanner = ClientSocketScanner()
                let other = host == "::1" ? "2001:db8::1" : "192.0.2.1"
                XCTAssertNil(scanner.pid(
                    clientAddress: other, clientPort: client.port!,
                    proxyAddress: host, proxyPort: proxy.port!
                ))
                XCTAssertNil(scanner.pid(
                    clientAddress: host, clientPort: client.port!,
                    proxyAddress: other, proxyPort: proxy.port!
                ))
            }
        }
    }

    func testSocketInheritedByAnotherProcessIsAmbiguous() throws {
        try withConnection(host: "127.0.0.1") { descriptor, client, proxy in
            let child = Process()
            child.executableURL = URL(fileURLWithPath: "/bin/cat")
            child.standardInput = FileHandle(fileDescriptor: descriptor, closeOnDealloc: false)
            child.standardOutput = FileHandle.nullDevice
            child.standardError = FileHandle.nullDevice
            try child.run()
            defer {
                child.terminate()
                child.waitUntilExit()
            }
            XCTAssertNil(owner(ClientSocketScanner(), client: client, proxy: proxy))
        }
    }

    func testHelpersNormalizeToContainingApplication() {
        XCTAssertEqual(
            ClientIdentity.outermostBundlePath(for: "/Applications/Browser.app/Contents/Frameworks/Browser Helper.app/Contents/MacOS/Browser Helper"),
            "/Applications/Browser.app"
        )
        XCTAssertEqual(
            ClientIdentity.outermostBundlePath(for: "/Applications/Browser.app/Contents/MacOS/Browser"),
            "/Applications/Browser.app"
        )
        XCTAssertNil(ClientIdentity.outermostBundlePath(for: "/usr/bin/curl"))
        XCTAssertNil(ClientIdentity.outermostBundlePath(for: "/tmp/not.app.backup/curl"))
    }

    func testResolverNamesLiveExecutableWithoutCachingExitedPID() throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sleep")
        child.arguments = ["30"]
        try child.run()
        defer {
            if child.isRunning {
                child.terminate()
                child.waitUntilExit()
            }
        }
        let resolver = ClientAppResolver(probe: FixedOwner(pid: child.processIdentifier))
        let live = expectation(description: "live executable identity")
        resolver.resolveClientApp(clientAddress: "127.0.0.1", clientPort: 10000, proxyAddress: "127.0.0.1", proxyPort: 9090) { app in
            XCTAssertEqual(app?.pid, child.processIdentifier)
            XCTAssertEqual(app?.name, "sleep")
            XCTAssertEqual(app?.path, "/bin/sleep")
            XCTAssertFalse(Thread.isMainThread)
            live.fulfill()
        }
        wait(for: [live], timeout: 5)
        child.terminate()
        child.waitUntilExit()

        let exited = expectation(description: "exited process has no cached identity")
        resolver.resolveClientApp(clientAddress: "127.0.0.1", clientPort: 10000, proxyAddress: "127.0.0.1", proxyPort: 9090) { app in
            XCTAssertNil(app)
            exited.fulfill()
        }
        wait(for: [exited], timeout: 5)
        XCTAssertNil(ClientIdentity.client(for: -1))
    }

    private func owner(_ scanner: ClientSocketScanner, client: SocketAddress, proxy: SocketAddress) -> Int32? {
        scanner.pid(
            clientAddress: client.ipAddress!, clientPort: client.port!,
            proxyAddress: proxy.ipAddress!, proxyPort: proxy.port!
        )
    }

    private func withConnection(
        host: String,
        _ body: (Int32, SocketAddress, SocketAddress) throws -> Void
    ) throws {
        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }
        let listener = try ServerBootstrap(group: group)
            .childChannelOption(ChannelOptions.autoRead, value: false)
            .bind(host: host, port: 0).wait()
        defer { try? listener.close().wait() }
        let proxy = try XCTUnwrap(listener.localAddress)
        let descriptor = Darwin.socket(host == "::1" ? AF_INET6 : AF_INET, SOCK_STREAM, 0)
        guard descriptor >= 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        defer { Darwin.close(descriptor) }
        let result = proxy.withSockAddr { Darwin.connect(descriptor, $0, socklen_t($1)) }
        guard result == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }

        var storage = sockaddr_storage()
        var length = socklen_t(MemoryLayout<sockaddr_storage>.size)
        let status = withUnsafeMutablePointer(to: &storage) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                getsockname(descriptor, $0, &length)
            }
        }
        guard status == 0 else { throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO) }
        let client = withUnsafeBytes(of: storage) { bytes in
            host == "::1"
                ? SocketAddress(bytes.load(as: sockaddr_in6.self))
                : SocketAddress(bytes.load(as: sockaddr_in.self))
        }
        try body(descriptor, client, proxy)
    }
}

private struct FixedOwner: SocketOwnershipProbing {
    let pid: Int32

    func pid(clientAddress: String, clientPort: Int, proxyAddress: String, proxyPort: Int) -> Int32? {
        pid
    }
}
