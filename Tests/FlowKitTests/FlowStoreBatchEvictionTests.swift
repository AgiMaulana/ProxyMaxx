import XCTest
@testable import FlowKit

@MainActor
final class FlowStoreBatchEvictionTests: XCTestCase {
    private func makeFlow(
        id: UUID = UUID(),
        path: String = "/item"
    ) -> Flow {
        let request = HTTPRequest(
            method: "GET",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: path,
            headers: HTTPHeaders(),
            body: Data()
        )
        return Flow(id: id, request: request)
    }

    func testBatchUpsertPreservesIndicesForUpdates() {
        let store = FlowStore()
        let flowA = makeFlow(path: "/a")
        let flowB = makeFlow(path: "/b")
        let flowC = makeFlow(path: "/c")

        store.upsert([flowA, flowB, flowC])
        XCTAssertEqual(store.flows.count, 3)
        XCTAssertEqual(store.flows.map(\.path), ["/a", "/b", "/c"])

        // Update flowB and add flowD in a batch
        let flowBUpdated = makeFlow(id: flowB.id, path: "/b-updated")
        let flowD = makeFlow(path: "/d")

        store.upsert([flowBUpdated, flowD])
        XCTAssertEqual(store.flows.count, 4)
        XCTAssertEqual(store.flows[1].path, "/b-updated")
        XCTAssertEqual(store.flows[3].path, "/d")
    }

    func testChunkedEvictionPreservesPinnedFlows() {
        let store = FlowStore()
        store.maxFlows = 100

        // Create 100 flows
        var flows: [Flow] = []
        for i in 0..<100 {
            flows.append(makeFlow(path: "/item-\(i)"))
        }
        store.upsert(flows)
        XCTAssertEqual(store.flows.count, 100)

        // Pin the first 5 flows (oldest flows)
        let pinnedIDs = Set(flows.prefix(5).map(\.id))
        store.pin(ids: pinnedIDs)

        // Adding 1 new flow causes eviction:
        // Chunk size = max(64, 100 / 20) = 64
        // Target to remove = overflow (1) + 64 = 65 non-pinned flows
        let newFlow = makeFlow(path: "/item-100")
        store.upsert(newFlow)

        // The pinned flows MUST still be present!
        for pinnedID in pinnedIDs {
            XCTAssertTrue(store.flows.contains(where: { $0.id == pinnedID }), "Pinned flow \(pinnedID) was evicted!")
        }

        // Total count should now be reduced because chunked eviction freed a block of flows
        XCTAssertLessThanOrEqual(store.flows.count, 100)
    }

    func testAdaptivePublishInterval() {
        let store = FlowStore()
        // Below 5000 flows, default publish interval is 100 ms
        XCTAssertEqual(store.publishInterval, .milliseconds(100))

        // Populate with > 5000 flows
        var flows: [Flow] = []
        flows.reserveCapacity(5001)
        for i in 0...5000 {
            flows.append(makeFlow(path: "/p-\(i)"))
        }
        store.maxFlows = 10_000
        store.upsert(flows)

        // Above 5000 flows, adaptive publish interval slows to 250 ms to reduce SwiftUI redraw frequency
        XCTAssertEqual(store.publishInterval, .milliseconds(250))

        // Custom override overrides adaptive behavior
        store.publishInterval = .milliseconds(50)
        XCTAssertEqual(store.publishInterval, .milliseconds(50))

        store.resetPublishInterval()
        XCTAssertEqual(store.publishInterval, .milliseconds(250))
    }
}
