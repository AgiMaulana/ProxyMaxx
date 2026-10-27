import Foundation
import NIOCore
import NIOHTTP1
import FlowKit

/// Accumulates a single `Flow` as its request and response stream through the proxy,
/// emitting throttled snapshots to the engine so the UI can update live.
final class FlowRecorder: @unchecked Sendable {
    private let onEmit: (Flow) -> Void
    private let lock = NSLock()
    private var flow: Flow
    private var lastBodyEmit: Date

    /// Minimum interval between body-driven emissions to avoid flooding the UI.
    private let bodyEmitInterval: TimeInterval = 0.25

    /// Capture ceiling for one upgraded connection. The largest benchmarked debug
    /// need is a few hundred frames; beyond that the snapshot cost outweighs the value.
    private static let maximumWebSocketMessages = 500
    private static let maximumWebSocketBytes = 4 * 1024 * 1024
    private var webSocketBytes = 0

    init(flow: Flow, onEmit: @escaping (Flow) -> Void) {
        self.flow = flow
        self.onEmit = onEmit
        self.lastBodyEmit = Date()
    }

    var id: UUID {
        lock.lock(); defer { lock.unlock() }
        return flow.id
    }

    var current: Flow {
        lock.lock(); defer { lock.unlock() }
        return flow
    }

    private func mutate(forceEmit: Bool = true, _ body: (inout Flow) -> Void) {
        lock.lock()
        body(&flow)
        let snapshot = flow
        lock.unlock()
        if forceEmit {
            onEmit(snapshot)
        }
    }

    func setRequest(_ request: HTTPRequest, timing: FlowTiming, clientAddress: String?, isIntercepted: Bool) {
        mutate { flow in
            flow.request = request
            flow.timing = timing
            flow.clientAddress = clientAddress
            flow.isIntercepted = isIntercepted
        }
    }

    func markIntercepted() {
        mutate { $0.isIntercepted = true }
    }

    func responseHead(_ head: HTTPResponseHead) {
        let response = HTTPResponse(
            statusCode: Int(head.status.code),
            httpVersion: head.version.flowString,
            headers: FlowKit.HTTPHeaders(nio: head.headers),
            body: Data()
        )
        mutate { flow in
            flow.response = response
            flow.timing.responseStarted = Date()
        }
    }

    func appendResponseBody(_ data: Data) {
        guard !data.isEmpty else { return }
        let now = Date()
        let shouldEmit = now.timeIntervalSince(lastBodyEmit) >= bodyEmitInterval
        if shouldEmit { lastBodyEmit = now }
        mutate(forceEmit: shouldEmit) { flow in
            guard var response = flow.response else { return }
            response.body.append(data)
            flow.response = response
        }
    }

    func complete() {
        mutate { flow in
            flow.timing.end = Date()
        }
    }

    /// Record one frame that crossed an upgraded connection.
    ///
    /// Bounded per flow: a chatty socket would otherwise grow the flow, its snapshots,
    /// and the session log without limit. The relay keeps forwarding once the cap is
    /// reached; only capture stops.
    func appendWebSocketMessage(_ message: WebSocketMessage) {
        lock.lock()
        let recorded = flow.webSocketMessages ?? []
        guard recorded.count < Self.maximumWebSocketMessages,
              webSocketBytes + message.payload.count <= Self.maximumWebSocketBytes
        else {
            lock.unlock()
            return
        }
        webSocketBytes += message.payload.count
        flow.webSocketMessages = recorded + [message]
        let snapshot = flow
        lock.unlock()
        onEmit(snapshot)
    }

    /// Record a response that was produced locally by a Map Local rule instead of
    /// arriving from upstream, and close the flow out in one step.
    func serveLocal(_ response: HTTPResponse, source: String, delay: TimeInterval) {
        mutate { flow in
            let completedAt = Date()
            flow.response = response
            flow.localMapSource = source
            flow.timing.responseStarted = completedAt.addingTimeInterval(-delay)
            flow.timing.end = completedAt
        }
    }

    func fail(_ message: String) {
        mutate { flow in
            flow.error = message
            flow.timing.end = Date()
        }
    }

    /// Fill in the owning app once async attribution lands. Only in-flight flows are
    /// updated: a completed flow keeps the snapshots it already emitted, so late
    /// attribution never re-emits a finished row.
    func setClientApp(_ app: ClientApp?) {
        guard let app else { return }
        lock.lock()
        guard flow.clientApp != app, flow.timing.end == nil, flow.error == nil else {
            lock.unlock()
            return
        }
        flow.clientApp = app
        let snapshot = flow
        lock.unlock()
        onEmit(snapshot)
    }
}
