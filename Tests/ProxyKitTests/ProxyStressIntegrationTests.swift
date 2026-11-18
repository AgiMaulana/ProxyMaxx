import XCTest
import Foundation
@testable import ProxyKit
import CertKit
import FlowKit

final class ProxyStressIntegrationTests: XCTestCase {
    func testConcurrentFlowsEmitAllFinalSnapshotsWithoutLoss() throws {
        let ca = try CertificateAuthority(commonName: "Stress Test CA")
        let origin = try OriginServer(tls: false, body: "{\"status\":\"ok\"}")
        let originPort = try origin.start()
        defer { origin.stop() }

        let engine = try ProxyEngine(
            configuration: ProxyConfiguration(host: "127.0.0.1", port: 0, socksPort: nil),
            authority: ca
        )

        let tracker = TerminalFlowTracker()
        engine.onEvent = { tracker.record($0) }
        try engine.start()
        defer { engine.stop() }

        let proxyPort = engine.boundPort!
        let concurrency = 50
        let requestsPerWorker = 4
        let totalRequests = concurrency * requestsPerWorker

        let group = DispatchGroup()
        let queue = DispatchQueue(label: "stress.test.queue", attributes: .concurrent)

        for worker in 0..<concurrency {
            group.enter()
            queue.async {
                defer { group.leave() }
                for req in 0..<requestsPerWorker {
                    let process = Process()
                    process.executableURL = URL(fileURLWithPath: "/usr/bin/curl")
                    process.arguments = [
                        "-sS",
                        "--max-time", "15",
                        "--proxy", "http://127.0.0.1:\(proxyPort)",
                        "http://127.0.0.1:\(originPort)/req-\(worker)-\(req)"
                    ]
                    let pipe = Pipe()
                    process.standardOutput = pipe
                    process.standardError = pipe
                    try? process.run()
                    process.waitUntilExit()
                }
            }
        }

        let waitResult = group.wait(timeout: .now() + 30)
        XCTAssertEqual(waitResult, .success, "Concurrent curl requests timed out")

        // Wait for engine to emit all terminal snapshots
        let completedCount = tracker.waitForCompletedCount(totalRequests, timeout: 15)
        XCTAssertEqual(completedCount, totalRequests, "Expected \(totalRequests) completed flows, but got \(completedCount)")
        XCTAssertEqual(tracker.errorCount, 0, "No flows should have failed with error")
    }
}

private final class TerminalFlowTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var completedIDs: Set<UUID> = []
    private var errorIDs: Set<UUID> = []

    func record(_ event: ProxyEvent) {
        guard case .flow(let flow) = event else { return }
        lock.lock()
        defer { lock.unlock() }
        if flow.isCompleted {
            completedIDs.insert(flow.id)
        }
        if flow.error != nil {
            errorIDs.insert(flow.id)
        }
    }

    var errorCount: Int {
        lock.lock(); defer { lock.unlock() }
        return errorIDs.count
    }

    func waitForCompletedCount(_ target: Int, timeout: TimeInterval) -> Int {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            lock.lock()
            let count = completedIDs.count
            lock.unlock()
            if count >= target {
                return count
            }
            Thread.sleep(forTimeInterval: 0.05)
        }
        lock.lock(); defer { lock.unlock() }
        return completedIDs.count
    }
}
