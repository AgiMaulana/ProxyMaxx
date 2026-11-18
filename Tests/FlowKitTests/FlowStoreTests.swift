import XCTest
@testable import FlowKit

final class FlowStoreTests: XCTestCase {
    @MainActor
    func testBatchUpsertPreservesOrder() {
        let store = FlowStore()
        let flow1 = makeFlow(path: "/one")
        let flow2 = makeFlow(path: "/two")
        let flow3 = makeFlow(path: "/three")

        store.upsert([flow1, flow2, flow3])

        XCTAssertEqual(store.flows.count, 3)
        XCTAssertEqual(store.flows.map(\.id), [flow1.id, flow2.id, flow3.id])
        XCTAssertEqual(store.flow(withID: flow1.id)?.request.path, "/one")
        XCTAssertEqual(store.flow(withID: flow2.id)?.request.path, "/two")
        XCTAssertEqual(store.flow(withID: flow3.id)?.request.path, "/three")
    }

    @MainActor
    func testBatchUpsertUpdatesInPlace() {
        let store = FlowStore()
        let flow1 = makeFlow(path: "/one")
        let flow2 = makeFlow(path: "/two")
        let flow3 = makeFlow(path: "/three")

        store.upsert([flow1, flow2, flow3])
        XCTAssertEqual(store.flows.map(\.id), [flow1.id, flow2.id, flow3.id])

        var updatedFlow2 = flow2
        updatedFlow2.response = HTTPResponse(statusCode: 200)

        let flow4 = makeFlow(path: "/four")

        store.upsert([updatedFlow2, flow4])

        XCTAssertEqual(store.flows.count, 4)
        XCTAssertEqual(store.flows.map(\.id), [flow1.id, flow2.id, flow3.id, flow4.id])
        XCTAssertEqual(store.flows[1].response?.statusCode, 200)
        XCTAssertEqual(store.flow(withID: flow2.id)?.response?.statusCode, 200)
    }

    @MainActor
    func testBatchUpsertInBatchDuplicatesUpdateInPlace() {
        let store = FlowStore()
        let id = UUID()
        let initial = Flow(
            id: id,
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.test", port: 80, path: "/item")
        )
        var updated = initial
        updated.response = HTTPResponse(statusCode: 204)

        store.upsert([initial, updated])

        XCTAssertEqual(store.flows.count, 1)
        XCTAssertEqual(store.flows[0].id, id)
        XCTAssertEqual(store.flows[0].response?.statusCode, 204)
        XCTAssertEqual(store.flow(withID: id)?.response?.statusCode, 204)
    }

    @MainActor
    func testOneRevisionPerBatch() async throws {
        let store = FlowStore()
        store.publishInterval = .milliseconds(20)

        XCTAssertEqual(store.revision, 0)

        let flows = (0..<5).map { makeFlow(path: "/flow-\($0)") }
        store.upsert(flows)

        // Give the publish task enough time to fire
        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(store.revision, 1)

        let moreFlows = (5..<10).map { makeFlow(path: "/flow-\($0)") }
        store.upsert(moreFlows)

        try await Task.sleep(for: .milliseconds(60))

        XCTAssertEqual(store.revision, 2)
    }

    @MainActor
    func testChunkEvictionPreservesPinnedRows() {
        let store = FlowStore()
        store.maxFlows = 100

        let initialFlows = (0..<100).map { makeFlow(path: "/flow-\($0)") }
        store.upsert(initialFlows)
        XCTAssertEqual(store.flows.count, 100)

        let pinnedFlow10 = initialFlows[10]
        let pinnedFlow25 = initialFlows[25]
        store.pin(pinnedFlow10.id)
        store.pin(pinnedFlow25.id)

        XCTAssertTrue(store.isPinned(pinnedFlow10.id))
        XCTAssertTrue(store.isPinned(pinnedFlow25.id))

        // Upsert 1 more flow, pushing count to 101 (> 100)
        let newFlow = makeFlow(path: "/flow-100")
        store.upsert(newFlow)

        // Chunk eviction with maxFlows = 100:
        // chunkSize = max(64, 100 / 20) = 64
        // overflow = 101 - 100 = 1
        // targetToRemove = 1 + 64 = 65 unpinned flows
        // Expected count after removing 65 unpinned flows: 101 - 65 = 36
        XCTAssertEqual(store.flows.count, 36)
        XCTAssertLessThanOrEqual(store.flows.count, store.maxFlows)

        // Pinned rows must be preserved
        XCTAssertNotNil(store.flow(withID: pinnedFlow10.id))
        XCTAssertNotNil(store.flow(withID: pinnedFlow25.id))
        XCTAssertTrue(store.flows.contains(where: { $0.id == pinnedFlow10.id }))
        XCTAssertTrue(store.flows.contains(where: { $0.id == pinnedFlow25.id }))

        // Oldest unpinned rows must have been evicted
        XCTAssertNil(store.flow(withID: initialFlows[0].id))
        XCTAssertNil(store.flow(withID: initialFlows[1].id))
        XCTAssertNil(store.flow(withID: initialFlows[9].id))

        // Newest flow must be present
        XCTAssertNotNil(store.flow(withID: newFlow.id))

        // Index integrity check
        for (offset, flow) in store.flows.enumerated() {
            XCTAssertEqual(store.flow(withID: flow.id)?.id, flow.id)
            XCTAssertEqual(store.flows[offset].id, flow.id)
        }
    }

    @MainActor
    func testChunkEvictionAmortizesSubsequentAppends() {
        let store = FlowStore()
        store.maxFlows = 100

        let initialFlows = (0..<100).map { makeFlow(path: "/flow-\($0)") }
        store.upsert(initialFlows)
        XCTAssertEqual(store.flows.count, 100)

        // Trigger eviction
        store.upsert(makeFlow(path: "/trigger"))
        XCTAssertEqual(store.flows.count, 36)

        // Subsequent single appends do not trigger eviction while under maxFlows
        for i in 0..<10 {
            store.upsert(makeFlow(path: "/subsequent-\(i)"))
        }
        XCTAssertEqual(store.flows.count, 46)
    }

    @MainActor
    func testAdaptivePublishInterval() {
        let store = FlowStore()

        // Empty / small store (<= 5,000 flows): 100 ms
        XCTAssertEqual(store.publishInterval, .milliseconds(100))

        let flows = (0..<5_000).map { makeFlow(path: "/flow-\($0)") }
        store.upsert(flows)
        XCTAssertEqual(store.flows.count, 5_000)
        XCTAssertEqual(store.publishInterval, .milliseconds(100))

        // Above 5k flows: 250 ms
        store.upsert(makeFlow(path: "/flow-5001"))
        XCTAssertEqual(store.flows.count, 5_001)
        XCTAssertEqual(store.publishInterval, .milliseconds(250))

        // Custom override
        store.publishInterval = .milliseconds(50)
        XCTAssertEqual(store.publishInterval, .milliseconds(50))

        // Reset custom override returns to adaptive calculation
        store.resetPublishInterval()
        XCTAssertEqual(store.publishInterval, .milliseconds(250))
    }

    @MainActor
    func testSingleFlowUpsertWrapperPreservesBehavior() {
        let store = FlowStore()
        let flow1 = makeFlow(path: "/single1")
        let flow2 = makeFlow(path: "/single2")

        store.upsert(flow1)
        store.upsert(flow2)

        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.flows[0].id, flow1.id)
        XCTAssertEqual(store.flows[1].id, flow2.id)
    }

    @MainActor
    func testPinAndUnpinManagement() {
        let store = FlowStore()
        let id1 = UUID()
        let id2 = UUID()

        store.pin(ids: [id1, id2])
        XCTAssertTrue(store.isPinned(id1))
        XCTAssertTrue(store.isPinned(id2))
        XCTAssertEqual(store.pinnedIDsSet, [id1, id2])

        store.setPinned(false, for: id1)
        XCTAssertFalse(store.isPinned(id1))
        XCTAssertTrue(store.isPinned(id2))

        store.unpin(ids: [id2])
        XCTAssertFalse(store.isPinned(id2))
        XCTAssertTrue(store.pinnedIDsSet.isEmpty)
    }

    @MainActor
    func testPublishNowImmediatelyBumpsRevision() {
        let store = FlowStore()
        store.publishInterval = .seconds(60)

        store.upsert(makeFlow(path: "/immediate"))
        XCTAssertEqual(store.revision, 0)

        store.publishNow()
        XCTAssertEqual(store.revision, 1)
    }

    private func makeFlow(path: String) -> Flow {
        Flow(
            request: HTTPRequest(method: "GET", scheme: "https", host: "api.example.com", port: 443, path: path)
        )
    }
}
