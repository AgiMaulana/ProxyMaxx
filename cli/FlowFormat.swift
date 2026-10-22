import Foundation
import FlowKit

/// One flow rendered for a machine or a person. Shared by `serve` (live stream) and
/// `flows` (reading the session log) so both surface the identical shape — an agent
/// that parses one parses the other.
enum FlowFormat {
    /// The summary line `serve` streams and `flows` prints. `--flow-mode full` fills in
    /// the request/response detail; `summary` leaves it nil.
    struct Line: Encodable {
        var id: String
        var time: String
        var method: String
        var url: String
        var host: String
        var path: String
        var intercepted: Bool
        var status: Int?
        var state: String
        var error: String?
        var mappedLocally: Bool
        var localMapSource: String?
        var durationMs: Double?
        var requestBytes: Int
        var responseBytes: Int
        var contentType: String?
        var clientApp: String?
        var request: FullMessage?
        var response: FullMessage?
        var webSocketMessages: [WebSocketLine]?
    }

    /// One frame from a connection that upgraded. `payload` is text when the bytes are
    /// valid UTF-8 and a hex dump otherwise, matching how the inspector renders bodies.
    struct WebSocketLine: Encodable {
        var time: String
        var direction: String
        var opcode: String
        var isFinal: Bool
        var bytes: Int
        var payload: String
        var payloadEncoding: String
        var payloadTruncated: Bool
    }

    /// Details only `--flow-mode full` emits: headers plus a decoded UTF-8 body preview.
    struct FullMessage: Encodable {
        var headers: [[String: String]]
        var bodyText: String?
        var bodyTruncated: Bool
    }

    static func make(_ flow: Flow, mode: String) -> Line {
        var line = Line(
            id: flow.id.uuidString,
            time: isoFormatter.string(from: flow.timing.start),
            method: flow.method,
            url: flow.url,
            host: flow.host,
            path: flow.path,
            intercepted: flow.isIntercepted,
            status: flow.statusCode,
            state: flow.state.rawValue,
            error: flow.error,
            mappedLocally: flow.isMappedLocally,
            localMapSource: flow.localMapSource,
            durationMs: flow.timing.total.map { ($0 * 1000).rounded() },
            requestBytes: flow.requestBytes,
            responseBytes: flow.responseBytes,
            contentType: flow.response?.contentType?.essence,
            clientApp: flow.clientApp,
            request: nil,
            response: nil,
            webSocketMessages: nil
        )
        if mode == "full" {
            line.request = detail(from: flow.request.headers, body: flow.request.decodedBody)
            if let response = flow.response {
                line.response = detail(from: response.headers, body: response.decodedBody)
            }
            line.webSocketMessages = flow.webSocketMessages?.map(webSocketLine)
        }
        return line
    }

    /// Write one NDJSON line to stdout.
    static func emit(_ flow: Flow, mode: String) {
        guard let data = try? JSONEncoder().encode(make(flow, mode: mode)) else { return }
        FileHandle.standardOutput.write(data)
        FileHandle.standardOutput.write(Data("\n".utf8))
    }

    /// A single human-readable line, for `flows --text`.
    static func text(_ flow: Flow) -> String {
        let status = flow.error != nil ? "ERR" : (flow.statusCode.map(String.init) ?? "…")
        let duration = flow.timing.total.map { " · \(Int(($0 * 1000).rounded()))ms" } ?? ""
        return "\(flow.method) \(status) \(flow.url)\(duration)"
    }

    private static func webSocketLine(_ message: WebSocketMessage) -> WebSocketLine {
        let maxPreview = 64 * 1024
        let slice = message.payload.prefix(maxPreview)
        let text = String(data: slice, encoding: .utf8)
        return WebSocketLine(
            time: isoFormatter.string(from: message.timestamp),
            direction: message.direction.rawValue,
            opcode: message.opcode,
            isFinal: message.isFinal,
            bytes: message.payload.count,
            payload: text ?? BodyFormatting.hexDump(Data(slice)),
            payloadEncoding: text == nil ? "hex" : "text",
            payloadTruncated: message.payload.count > maxPreview
        )
    }

    private static func detail(from headers: HTTPHeaders, body: Data) -> FullMessage {
        let maxPreview = 64 * 1024
        var text: String?
        var truncated = false
        if body.count > 0 {
            let slice = body.prefix(maxPreview)
            text = String(decoding: slice, as: UTF8.self)
            truncated = body.count > maxPreview || text?.range(of: "\u{FFFD}") != nil
        }
        return FullMessage(
            headers: headers.entries.map { [$0.name: $0.value] },
            bodyText: text,
            bodyTruncated: truncated
        )
    }

    private static let isoFormatter: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return formatter
    }()
}
