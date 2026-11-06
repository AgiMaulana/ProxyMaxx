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
    /// Local socket owner, when macOS permits process attribution.
    public var clientApp: ClientApp?
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
        clientApp: ClientApp? = nil,
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

public extension Flow {
    /// The device the flow's peer address belongs to, once the engine has matched it against
    /// the devices `adb` reports. Not part of the session format: flows stored before the
    /// engine knew about devices keep nil, which `FlowFilter` treats as "no device".
    var connectedDevice: ConnectedDevice? { DeviceAttribution.connectedDevice(id: id) }
}

/// Device label for a peer address, resolved by the engine off the event loop.
public struct ConnectedDevice: Codable, Hashable, Sendable {
    /// `adb` serial, e.g. `emulator-5554`; the identity that survives a restart.
    public let serial: String
    /// Host-facing name shown in the sidebar, e.g. `Pixel 9 Pro (emulator-5554)`.
    public let name: String
    /// The address the device reached this Mac from.
    public let address: String

    public init(serial: String, name: String, address: String) {
        self.serial = serial
        self.name = name
        self.address = address
    }
}

/// Where the engine records which device a flow came from.
///
/// Flows are `Sendable` value types and are re-encoded constantly, so the label lives beside
/// them keyed by id instead of inside the struct. A bounded map keeps a long capture from
/// growing without limit; the traffic list only reads labels for the recent tail.
public enum DeviceAttribution {
    private static let lock = NSLock()
    nonisolated(unsafe) private static var labels: [UUID: ConnectedDevice] = [:]
    nonisolated(unsafe) private static var order: [UUID] = []
    private static let limit = 50_000

    public static func connectedDevice(id: UUID) -> ConnectedDevice? {
        lock.lock(); defer { lock.unlock() }
        return labels[id]
    }

    public static func record(_ device: ConnectedDevice, for id: UUID) {
        lock.lock(); defer { lock.unlock() }
        if labels.updateValue(device, forKey: id) == nil { order.append(id) }
        if order.count > limit {
            let excess = order.count - limit
            for stale in order.prefix(excess) { labels.removeValue(forKey: stale) }
            order.removeFirst(excess)
        }
    }

    public static func forget(id: UUID) {
        lock.lock(); defer { lock.unlock() }
        labels.removeValue(forKey: id)
    }

    public static func reset() {
        lock.lock(); defer { lock.unlock() }
        labels.removeAll()
        order.removeAll()
    }
}
