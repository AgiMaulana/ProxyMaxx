import Foundation
import Branding

// The Chromium native messaging host for the ProxyMaxx browser extension.
//
// Chrome launches this process, writes one length-prefixed JSON message to stdin, and
// reads one back from stdout. Nothing else may reach stdout: a stray byte is a protocol
// violation and Chrome tears the channel down.
//
// It is deliberately stateless. The Mac app writes `browser-bridge.json` whenever its
// state changes; this process only reads that file and answers. No socket, no daemon,
// no IPC — the same shape as the Android contract, where the app configures the
// companion once and the companion serves from what it was told.

let hostName = "com.proxymaxx.browser"

func stateFileURL() -> URL {
    Brand.supportDirectory.appendingPathComponent("browser-bridge.json")
}

/// Whether something accepts TCP connections on the loopback port right now.
///
/// A loopback connect either succeeds immediately or is refused immediately, so this never
/// blocks on a network round trip and needs no timeout. Only this process can answer the
/// question — the extension has no way to open a socket, so without it the popup can only
/// guess whether the app is actually serving.
func portIsListening(_ port: Int) -> Bool {
    guard port > 0, port <= 65535 else { return false }

    let handle = Darwin.socket(AF_INET, SOCK_STREAM, 0)
    guard handle >= 0 else { return false }
    defer { Darwin.close(handle) }

    var address = sockaddr_in()
    address.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
    address.sin_family = sa_family_t(AF_INET)
    address.sin_port = in_port_t(UInt16(port).bigEndian)
    address.sin_addr.s_addr = inet_addr("127.0.0.1")

    let result = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) { generic in
            Darwin.connect(handle, generic, socklen_t(MemoryLayout<sockaddr_in>.size))
        }
    }
    return result == 0
}

/// Read the app's published state, or report that there is none.
///
/// The reply is always a JSON object: Chrome rejects arrays and scalars.
func reply(for message: [String: Any]) -> [String: Any] {
    let kind = message["type"] as? String ?? "hello"
    guard kind == "hello" || kind == "status" || kind == "ping" else {
        return ["ok": false, "reason": "unknown_message", "type": kind]
    }

    guard
        let data = try? Data(contentsOf: stateFileURL()),
        let state = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    else {
        return ["ok": false, "reason": "app_not_running", "host": hostName]
    }

    var answer = state
    answer["ok"] = true
    answer["host"] = hostName
    if let port = state["httpPort"] as? Int {
        answer["proxyListening"] = portIsListening(port)
    }
    return answer
}

/// Read exactly `count` bytes, or nil at end of input.
func readExactly(_ count: Int) -> Data? {
    var buffer = [UInt8](repeating: 0, count: count)
    var filled = 0
    while filled < count {
        let read = buffer.withUnsafeMutableBytes { raw -> Int in
            guard let base = raw.baseAddress else { return 0 }
            return Darwin.read(STDIN_FILENO, base.advanced(by: filled), count - filled)
        }
        if read <= 0 { return nil }
        filled += read
    }
    return Data(buffer)
}

func write(_ message: [String: Any]) {
    guard let payload = try? JSONSerialization.data(withJSONObject: message) else { return }
    var length = UInt32(payload.count).littleEndian
    FileHandle.standardOutput.write(withUnsafeBytes(of: &length) { Data($0) })
    FileHandle.standardOutput.write(payload)
}

let maximumMessageSize = 64 * 1024 * 1024

while true {
    // Chrome writes the length as a native-endian UInt32, which is little-endian here.
    guard let header = readExactly(4) else { break }
    let length = header.withUnsafeBytes { $0.loadUnaligned(as: UInt32.self).littleEndian }
    guard length > 0, length <= UInt32(maximumMessageSize) else { break }
    guard let body = readExactly(Int(length)) else { break }

    let message = (try? JSONSerialization.jsonObject(with: body)) as? [String: Any] ?? [:]
    write(reply(for: message))
}
