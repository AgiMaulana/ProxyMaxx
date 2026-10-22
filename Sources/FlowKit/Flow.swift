import Foundation

/// Where a flow originated.
public enum FlowSource: String, Codable, Sendable, CaseIterable {
    /// Captured through the local HTTP/HTTPS proxy.
    case local
    /// Captured from a remote device (iOS/Android) pointed at this proxy.
    case remoteDevice
    /// Captured through the transparent (Network Extension) proxy.
    case transparent
}

/// A single captured request/response transaction.
public struct Flow: Identifiable, Codable, Sendable {
    public var id: UUID
    public var request: HTTPRequest
    public var response: HTTPResponse?
    public var timing: FlowTiming
    /// True when the connection was TLS-terminated and decrypted by the proxy.
    public var isIntercepted: Bool
    /// Bundle name of the client that issued the request, when resolvable.
    public var clientApp: String?
    /// `ip:port` of the originating socket, when known.
    public var clientAddress: String?
    public var source: FlowSource
    public var error: String?
    /// Set when the response was answered from a Map Local file or directory, in which
    /// case this names what was served. Nil for a response that came from the network.
    public var localMapSource: String?
    /// Frames exchanged after a `101 Switching Protocols` response. Nil on everything
    /// that is not a WebSocket flow; optional so session logs written before frame
    /// capture existed still decode.
    public var webSocketMessages: [WebSocketMessage]?

    public var isPinned: Bool
    public var colorTag: Int?
    public var comment: String?

    public init(
        id: UUID = UUID(),
        request: HTTPRequest,
        response: HTTPResponse? = nil,
        timing: FlowTiming = FlowTiming(),
        isIntercepted: Bool = false,
        clientApp: String? = nil,
        clientAddress: String? = nil,
        source: FlowSource = .local,
        error: String? = nil,
        localMapSource: String? = nil,
        webSocketMessages: [WebSocketMessage]? = nil,
        isPinned: Bool = false,
        colorTag: Int? = nil,
        comment: String? = nil
    ) {
        self.id = id
        self.request = request
        self.response = response
        self.timing = timing
        self.isIntercepted = isIntercepted
        self.clientApp = clientApp
        self.clientAddress = clientAddress
        self.source = source
        self.error = error
        self.localMapSource = localMapSource
        self.webSocketMessages = webSocketMessages
        self.isPinned = isPinned
        self.colorTag = colorTag
        self.comment = comment
    }

    public var host: String { request.host }
    public var method: String { request.method }
    public var url: String { request.urlString }
    public var path: String { request.path }
    public var statusCode: Int? { response?.statusCode }
    public var isPending: Bool { response == nil && error == nil }
    /// True when this response came from a Map Local rule rather than the network.
    public var isMappedLocally: Bool { localMapSource != nil }
    public var state: FlowState {
        if error != nil { return .failed }
        if response != nil { return .completed }
        return .pending
    }
}

public enum FlowState: String, Sendable {
    case pending
    case completed
    case failed
}

public extension Flow {
    /// Total bytes on the wire for this flow (headers are not counted in detail).
    var responseBytes: Int { response?.body.count ?? 0 }
    var requestBytes: Int { request.body.count }
}
