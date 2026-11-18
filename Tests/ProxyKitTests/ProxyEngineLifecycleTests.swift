import XCTest
import Foundation
import NIOCore
import NIOPosix
@testable import ProxyKit
import CertKit
import FlowKit

final class ProxyEngineLifecycleTests: XCTestCase {
    func testStopShutsDownOwnedEventLoopGroup() throws {
        let ca = try CertificateAuthority(commonName: "Lifecycle Test CA")
        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: ca
        )
        try engine.start()
        XCTAssertTrue(engine.isRunning)

        engine.stop()
        XCTAssertFalse(engine.isRunning)
        XCTAssertNil(engine.boundPort)
    }

    func testUpstreamHandlerDoesNotRetainEngine() throws {
        let ca = try CertificateAuthority(commonName: "Lifecycle Test CA")
        var engine: ProxyEngine? = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: ca
        )
        weak var weakEngine: ProxyEngine?
        weakEngine = engine

        let group = MultiThreadedEventLoopGroup(numberOfThreads: 1)
        defer { try? group.syncShutdownGracefully() }

        let clientChannel = try ServerBootstrap(group: group)
            .bind(host: "127.0.0.1", port: 0)
            .wait()
        defer { try? clientChannel.close().wait() }

        let recorder = FlowRecorder(
            flow: Flow(request: HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/")),
            onEmit: { _ in }
        )

        let handler = UpstreamHandler(
            clientChannel: clientChannel,
            recorder: recorder,
            engine: engine!,
            clientKeepAlive: false,
            host: "example.com"
        )
        _ = handler // retain handler

        // Now deallocate the engine reference
        engine?.stop()
        engine = nil

        // Handler holds weak reference, so engine must deallocate cleanly without retain cycle
        XCTAssertNil(weakEngine, "UpstreamHandler must not create a strong retain cycle to ProxyEngine")
    }
}
