import XCTest
import Foundation
@testable import FlowKit

@MainActor
final class FlowStoreByteCapTests: XCTestCase {
    private func makeFlow(id: UUID = UUID(), bodySize: Int, isPinned: Bool = false) -> Flow {
        let body = Data(repeating: 0x41, count: bodySize)
        let request = HTTPRequest(
            method: "POST",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: "/test",
            body: body
        )
        return Flow(id: id, request: request, isPinned: isPinned)
    }

    func testPayloadBytesTracking() {
        let store = FlowStore()
        let id1 = UUID()
        let flow1 = makeFlow(id: id1, bodySize: 100)
        store.upsert(flow1)

        XCTAssertEqual(store.totalPayloadBytes, 100)

        // Update existing flow with larger body
        let flow1Updated = makeFlow(id: id1, bodySize: 250)
        store.upsert(flow1Updated)

        XCTAssertEqual(store.totalPayloadBytes, 250)
        XCTAssertEqual(store.flows.count, 1)

        // Add a second flow
        let flow2 = makeFlow(bodySize: 150)
        store.upsert(flow2)

        XCTAssertEqual(store.totalPayloadBytes, 400)
        XCTAssertEqual(store.flows.count, 2)
    }

    func testByteBudgetEviction() {
        let store = FlowStore()
        store.maxBytes = 500
        store.maxFlows = 100

        let flow1 = makeFlow(bodySize: 200)
        let flow2 = makeFlow(bodySize: 200)
        let flow3 = makeFlow(bodySize: 200)

        store.upsert(flow1)
        store.upsert(flow2)
        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.totalPayloadBytes, 400)

        // Adding flow3 pushes total bytes to 600 (> 500). Oldest (flow1) should be evicted.
        store.upsert(flow3)
        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.flows.map(\.id), [flow2.id, flow3.id])
        XCTAssertEqual(store.totalPayloadBytes, 400)
    }

    func testPinnedFlowsPreservedUnderByteBudget() {
        let store = FlowStore()
        store.maxBytes = 450
        store.maxFlows = 10

        let flow1 = makeFlow(bodySize: 100, isPinned: false)
        let pinnedFlow = makeFlow(bodySize: 200, isPinned: true)
        let flow3 = makeFlow(bodySize: 200, isPinned: false)

        store.upsert(flow1)
        store.upsert(pinnedFlow)
        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.totalPayloadBytes, 300)

        // Adding flow3 pushes total bytes to 500 (> 450).
        // flow1 (oldest unpinned) is evicted, but pinnedFlow is preserved even though it is older than flow3.
        store.upsert(flow3)
        XCTAssertEqual(store.flows.count, 2)
        XCTAssertEqual(store.flows.map(\.id), [pinnedFlow.id, flow3.id])
        XCTAssertEqual(store.totalPayloadBytes, 400)
        XCTAssertTrue(store.isPinned(pinnedFlow.id))
    }

    func testClearAndRemoveUpdateByteBudget() {
        let store = FlowStore()
        let flow1 = makeFlow(bodySize: 100)
        let flow2 = makeFlow(bodySize: 200)

        store.upsert(flow1)
        store.upsert(flow2)
        XCTAssertEqual(store.totalPayloadBytes, 300)

        store.remove(ids: [flow1.id])
        XCTAssertEqual(store.totalPayloadBytes, 200)
        XCTAssertEqual(store.flows.count, 1)

        store.clear()
        XCTAssertEqual(store.totalPayloadBytes, 0)
        XCTAssertEqual(store.flows.count, 0)
    }
}
