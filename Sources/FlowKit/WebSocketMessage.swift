import Foundation

/// One frame observed on a WebSocket connection the proxy decrypted.
///
/// Frames are recorded against the flow that carried the opening handshake, in the
/// order they crossed the proxy, so the inspector can show what happened after the
/// `101 Switching Protocols`.
public struct WebSocketMessage: Codable, Hashable, Sendable {
    /// Which end of the connection produced the frame.
    public enum Direction: String, Codable, Sendable {
        case clientToServer
        case serverToClient
    }

    public var timestamp: Date
    public var direction: Direction
    /// Wire opcode: `text`, `binary`, `continuation`, `close`, `ping`, `pong`, or
    /// `reserved` for the values RFC 6455 leaves unassigned.
    public var opcode: String
    /// False for a fragment that another frame continues.
    public var isFinal: Bool
    /// Payload after unmasking. Control frames carry at most 125 bytes.
    public var payload: Data

    public init(
        timestamp: Date = Date(),
        direction: Direction,
        opcode: String,
        isFinal: Bool,
        payload: Data
    ) {
        self.timestamp = timestamp
        self.direction = direction
        self.opcode = opcode
        self.isFinal = isFinal
        self.payload = payload
    }
}
