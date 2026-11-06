import Foundation
import FlowKit

/// Who a flow came from, as far as the proxy can tell.
///
/// The HTTP and SOCKS5 listeners accept connections from macOS processes and from devices
/// on the network alike, and both look the same at the socket: a loopback peer means a
/// process on this Mac, anything else came from a phone or an emulator. `connectedDevice`
/// is filled in by the engine for peer addresses that belong to a device `adb` reports.
public enum FlowOrigin: String, Codable, Sendable {
    case local
    case remoteDevice
}

public extension Flow {
    var origin: FlowOrigin {
        guard let clientAddress, let peer = Flow.remotePeer(of: clientAddress) else {
            return .local
        }
        if Flow.isLoopback(peer) {
            // A loopback peer is a process on this Mac, except the Android emulator's network
            // stack: qemu's `netsimd` opens a loopback socket to the proxy for traffic that
            // started inside the emulator. That process must not be presented as the client,
            // because it says nothing about which device sent the request.
            return Flow.isEmulatorForwarder(clientApp) ? .remoteDevice : .local
        }
        return .remoteDevice
    }

    /// True for the process that relays an emulator's connections into this Mac.
    static func isEmulatorForwarder(_ app: ClientApp?) -> Bool {
        guard let app else { return false }
        if app.name.caseInsensitiveCompare("netsimd") == .orderedSame { return true }
        return app.path?.hasSuffix("/netsimd") == true
    }

    /// The IP part of `clientAddress` (`ip:port`, IPv6 in brackets), or nil when unparsable.
    static func remotePeer(of clientAddress: String) -> String? {
        guard let colon = clientAddress.lastIndex(of: ":") else { return nil }
        let peer = String(clientAddress[clientAddress.startIndex..<colon])
        let bare = peer.hasPrefix("[") && peer.hasSuffix("]") ? String(peer.dropFirst().dropLast()) : peer
        return bare.isEmpty ? nil : bare
    }

    /// True for the addresses a connection from this Mac arrives on.
    ///
    /// IPv6 peers arrive as `::1` or in IPv4-mapped form (`::ffff:127.0.0.1`), which NIO
    /// reports verbatim, so both spellings count.
    static func isLoopback(_ peer: String) -> Bool {
        if peer == "::1" || peer.caseInsensitiveCompare("localhost") == .orderedSame { return true }
        let ipv4 = peer.lowercased().hasPrefix("::ffff:") ? String(peer.dropFirst("::ffff:".count)) : peer
        return ipv4.hasPrefix("127.")
    }
}
