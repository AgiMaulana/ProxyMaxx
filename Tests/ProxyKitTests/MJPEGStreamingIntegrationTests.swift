import XCTest
import Foundation
import NIOCore
import NIOPosix
import NIOHTTP1
@testable import ProxyKit
import CertKit
import FlowKit

/// Integration test for Phase 7:
/// Local server streams 100 MB chunked MJPEG; client receives all bytes, capture stays capped, memory stays stable.
final class MJPEGStreamingIntegrationTests: XCTestCase {
    func testChunkedMJPEGStreamReceivesAllBytesWhileCaptureStaysCapped() throws {
        let ca = try CertificateAuthority(commonName: "MJPEG Test CA")

        // 100 MB stream composed of 100 chunks of 1 MB payload each
        let totalTargetBytes = 100 * 1024 * 1024
        let chunkSize = 1024 * 1024
        let chunkCount = totalTargetBytes / chunkSize

        let server = try MJPEGStreamServer(chunkSize: chunkSize, chunkCount: chunkCount)
        let serverPort = try server.start()
        defer { server.stop() }

        let config = ProxyConfiguration(
            host: "127.0.0.1",
            port: 0,
            socksPort: nil,
            maxCapturedResponseBodyBytes: 8 * 1024 * 1024,
            streamingBodyCaptureBytes: 256 * 1024, // 256 KiB capture cap
            liveBodyEmitBytes: 512 * 1024
        )
        let engine = try ProxyEngine(configuration: config, authority: ca)

        let snapshotCounter = SnapshotCounter()
        engine.onEvent = { snapshotCounter.handle($0) }
        try engine.start()
        defer { engine.stop() }

        // Use curl to download the 100 MB stream through the proxy, discarding body to /dev/null
        // and writing total bytes received via %{size_download}
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
        process.arguments = [
            "-sS",
            "--max-time", "60",
            "--proxy", "http://127.0.0.1:\(engine.boundPort!)",
            "http://127.0.0.1:\(serverPort)/stream.mjpeg",
            "-o", "/dev/null",
            "-w", "%{size_download}"
        ]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let outputData = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()

        let curlOutput = String(decoding: outputData, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        XCTAssertEqual(process.terminationStatus, 0, "curl failed with output: \(curlOutput)")

        guard let bytesReceived = Int(curlOutput) else {
            XCTFail("Failed to parse curl size_download: \(curlOutput)")
            return
        }

        // 1. Client must have received all 100 MB of stream data
        XCTAssertGreaterThanOrEqual(bytesReceived, totalTargetBytes, "Client did not receive full stream bytes!")

        // 2. Wait for the completed flow recorded by the engine
        guard let completedFlow = snapshotCounter.waitForCompletedFlow(timeout: 10) else {
            XCTFail("Engine never emitted completed flow")
            return
        }

        // 3. Captured body must be strictly capped at streamingBodyCaptureBytes (256 KiB)
        let capturedBodyCount = completedFlow.response?.body.count ?? 0
        XCTAssertLessThanOrEqual(capturedBodyCount, config.streamingBodyCaptureBytes, "Captured body exceeded 256 KiB cap!")
        XCTAssertGreaterThan(capturedBodyCount, 0)

        // 4. Flags must accurately reflect streaming and truncation
        XCTAssertEqual(completedFlow.isStreamingResponse, true, "Flow should be detected as streaming response")
        XCTAssertEqual(completedFlow.isResponseBodyTruncated, true, "Flow responseBodyTruncated flag must be true")
        XCTAssertTrue(completedFlow.isCompleted, "Flow must be marked completed")

        // 5. Total snapshots emitted for this flow must be bounded (stopped after cap)
        let totalEmits = snapshotCounter.snapshotCount(for: completedFlow.id)
        XCTAssertLessThanOrEqual(totalEmits, 10, "Engine emitted too many snapshots for capped stream: \(totalEmits)")
    }
}

// MARK: - Mock MJPEG Streaming Server

private final class MJPEGStreamServer {
    private let group: MultiThreadedEventLoopGroup
    private var channel: Channel?
    private let chunkSize: Int
    private let chunkCount: Int

    init(chunkSize: Int, chunkCount: Int) throws {
        self.group = MultiThreadedEventLoopGroup(numberOfThreads: 2)
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
    }

    func start() throws -> Int {
        let chunkSize = self.chunkSize
        let chunkCount = self.chunkCount
        let bootstrap = ServerBootstrap(group: group)
            .serverChannelOption(ChannelOptions.socketOption(.so_reuseaddr), value: 1)
            .childChannelInitializer { channel in
                channel.pipeline.addHandler(HTTPResponseEncoder()).flatMap {
                    channel.pipeline.addHandler(ByteToMessageHandler(HTTPRequestDecoder()))
                }.flatMap {
                    channel.pipeline.addHandler(MJPEGStreamHandler(chunkSize: chunkSize, chunkCount: chunkCount))
                }
            }
        let channel = try bootstrap.bind(host: "127.0.0.1", port: 0).wait()
        self.channel = channel
        return channel.localAddress?.port ?? 0
    }

    func stop() {
        try? channel?.close().wait()
        channel = nil
        try? group.syncShutdownGracefully()
    }
}

private final class MJPEGStreamHandler: ChannelInboundHandler {
    typealias InboundIn = HTTPServerRequestPart
    typealias OutboundOut = HTTPServerResponsePart

    private let chunkSize: Int
    private let chunkCount: Int

    init(chunkSize: Int, chunkCount: Int) {
        self.chunkSize = chunkSize
        self.chunkCount = chunkCount
    }

    func channelRead(context: ChannelHandlerContext, data: NIOAny) {
        guard case .end = unwrapInboundIn(data) else { return }

        var headers = NIOHTTP1.HTTPHeaders()
        headers.add(name: "Content-Type", value: "multipart/x-mixed-replace; boundary=--myboundary")
        headers.add(name: "Transfer-Encoding", value: "chunked")

        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: headers)
        context.write(wrapOutboundOut(.head(head)), promise: nil)

        let chunkPayload = Data(repeating: 0x55, count: chunkSize)
        let boundaryPrefix = Data("--myboundary\r\nContent-Type: image/jpeg\r\nContent-Length: \(chunkSize)\r\n\r\n".utf8)
        let boundarySuffix = Data("\r\n".utf8)

        // Stream all frames sequentially
        func sendChunk(remaining: Int) {
            guard remaining > 0 else {
                context.writeAndFlush(wrapOutboundOut(.end(nil))).whenComplete { _ in
                    context.close(promise: nil)
                }
                return
            }

            var buffer = context.channel.allocator.buffer(capacity: boundaryPrefix.count + chunkPayload.count + boundarySuffix.count)
            buffer.writeBytes(boundaryPrefix)
            buffer.writeBytes(chunkPayload)
            buffer.writeBytes(boundarySuffix)

            context.writeAndFlush(wrapOutboundOut(.body(.byteBuffer(buffer)))).whenComplete { result in
                switch result {
                case .success:
                    context.eventLoop.execute {
                        sendChunk(remaining: remaining - 1)
                    }
                case .failure:
                    context.close(promise: nil)
                }
            }
        }

        sendChunk(remaining: chunkCount)
    }
}

// MARK: - Snapshot Counter Helper

private final class SnapshotCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var flowsByID: [UUID: Flow] = [:]
    private var countsByID: [UUID: Int] = [:]
    private var completedFlows: [Flow] = []

    func handle(_ event: ProxyEvent) {
        guard case .flow(let flow) = event else { return }
        lock.lock()
        defer { lock.unlock() }
        flowsByID[flow.id] = flow
        countsByID[flow.id, default: 0] += 1
        if flow.isCompleted {
            completedFlows.append(flow)
        }
    }

    func snapshotCount(for id: UUID) -> Int {
        lock.lock(); defer { lock.unlock() }
        return countsByID[id] ?? 0
    }

    func waitForCompletedFlow(timeout: TimeInterval) -> Flow? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            if let flow = completedFlows.first {
                lock.unlock()
                return flow
            }
            lock.unlock()
            Thread.sleep(forTimeInterval: 0.05)
        }
        return nil
    }
}
