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
    private let configuration: ProxyConfiguration
    private var bodyEmitsStopped = false
    private var totalResponseBodyBytes = 0

    /// Minimum interval between body-driven emissions to avoid flooding the UI.
    private let bodyEmitInterval: TimeInterval = 0.25

    /// Capture ceiling for one upgraded connection. The largest benchmarked debug
    /// need is a few hundred frames; beyond that the snapshot cost outweighs the value.
    private static let maximumWebSocketMessages = 500
    private static let maximumWebSocketBytes = 4 * 1024 * 1024
    private var webSocketBytes = 0

    init(
        flow: Flow,
        configuration: ProxyConfiguration = ProxyConfiguration(),
        onEmit: @escaping (Flow) -> Void
    ) {
        self.flow = flow
        self.configuration = configuration
        self.onEmit = onEmit
        self.lastBodyEmit = Date()
        if self.flow.request.body.count > configuration.maxCapturedRequestBodyBytes {
            self.flow.request.body = self.flow.request.body.prefix(configuration.maxCapturedRequestBodyBytes)
            self.flow.requestBodyTruncated = true
        }
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
            var req = request
            if req.body.count > configuration.maxCapturedRequestBodyBytes {
                req.body = req.body.prefix(configuration.maxCapturedRequestBodyBytes)
                flow.requestBodyTruncated = true
            }
            flow.request = req
            flow.timing = timing
            flow.clientAddress = clientAddress
            flow.isIntercepted = isIntercepted
        }
    }

    func markIntercepted() {
        mutate { $0.isIntercepted = true }
    }

    static func isStreamingResponse(headers: FlowKit.HTTPHeaders) -> Bool {
        guard let contentType = headers.contentType else { return false }
        let essence = contentType.essence
        if essence == "multipart/x-mixed-replace" || essence == "text/event-stream" {
            return true
        }
        if contentType.type == "video" || contentType.type == "audio" {
            if headers["Content-Length"] == nil || headers["Transfer-Encoding"]?.lowercased().contains("chunked") == true {
                return true
            }
        }
        return false
    }

    func responseHead(_ head: HTTPResponseHead) {
        let headers = FlowKit.HTTPHeaders(nio: head.headers)
        let streaming = Self.isStreamingResponse(headers: headers)
        let response = HTTPResponse(
            statusCode: Int(head.status.code),
            httpVersion: head.version.flowString,
            headers: headers,
            body: Data()
        )
        mutate { flow in
            flow.response = response
            flow.timing.responseStarted = Date()
            if streaming {
                flow.isStreamingResponse = true
            }
        }
    }

    func appendResponseBody(_ data: Data) {
        guard !data.isEmpty else { return }
        let now = Date()
        lock.lock()
        guard var response = flow.response else {
            lock.unlock()
            return
        }

        totalResponseBodyBytes += data.count

        // Long-lived media detection: video/* or audio/* that continues streaming
        if flow.isStreamingResponse != true,
           let contentType = response.contentType,
           (contentType.type == "video" || contentType.type == "audio") {
            let elapsed = flow.timing.responseStarted.map { now.timeIntervalSince($0) } ?? 0
            if elapsed >= 1.0 || totalResponseBodyBytes > configuration.streamingBodyCaptureBytes {
                flow.isStreamingResponse = true
            }
        }

        let cap = (flow.isStreamingResponse == true)
            ? configuration.streamingBodyCaptureBytes
            : configuration.maxCapturedResponseBodyBytes

        let currentCount = response.body.count
        if currentCount < cap {
            let available = cap - currentCount
            if data.count > available {
                response.body.append(data.prefix(available))
                flow.responseBodyTruncated = true
            } else {
                response.body.append(data)
            }
        } else {
            flow.responseBodyTruncated = true
        }
        flow.response = response

        let isCapped = flow.responseBodyTruncated == true
        let exceedsLiveLimit = (flow.response?.body.count ?? 0) >= configuration.liveBodyEmitBytes

        var shouldEmit = false
        if !bodyEmitsStopped {
            let intervalPassed = now.timeIntervalSince(lastBodyEmit) >= bodyEmitInterval
            if isCapped || exceedsLiveLimit {
                shouldEmit = true
                bodyEmitsStopped = true
                lastBodyEmit = now
            } else if intervalPassed {
                shouldEmit = true
                lastBodyEmit = now
            }
        }
        let snapshot = flow
        lock.unlock()

        if shouldEmit {
            onEmit(snapshot)
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
            var resp = response
            if resp.body.count > configuration.maxCapturedResponseBodyBytes {
                resp.body = resp.body.prefix(configuration.maxCapturedResponseBodyBytes)
                flow.responseBodyTruncated = true
            }
            flow.response = resp
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
