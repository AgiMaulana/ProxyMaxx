import Foundation
import NIOHTTP1

/// A resolved upstream target for one request.
struct ResolvedTarget: Sendable {
    var scheme: String
    var host: String
    var port: Int
    /// Origin-form path plus query, e.g. `/api/v1?x=1`.
    var path: String
    /// True when this request arrived over a decrypted CONNECT tunnel.
    var isIntercepted: Bool

    var isTLS: Bool {
        let scheme = scheme.lowercased()
        return scheme == "https" || scheme == "wss"
    }

    var hostHeader: String {
        let isDefault = (isTLS && port == 443) || (!isTLS && port == 80)
        return isDefault ? host : "\(host):\(port)"
    }
}

enum TargetParser {
    /// Parse `host:port` (or bare host) honouring IPv6 bracket notation.
    static func parseHostPort(_ value: String, defaultPort: Int) -> (host: String, port: Int) {
        let trimmed = value.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") {
            let host = String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            let rest = trimmed[trimmed.index(after: end)...]
            if rest.hasPrefix(":"), let port = Int(rest.dropFirst()) {
                return (host, port)
            }
            return (host, defaultPort)
        }
        if trimmed.filter({ $0 == ":" }).count == 1, let colon = trimmed.lastIndex(of: ":") {
            let host = String(trimmed[..<colon])
            if let port = Int(trimmed[trimmed.index(after: colon)...]), !host.isEmpty {
                return (host, port)
            }
        }
        return (trimmed, defaultPort)
    }

    /// Resolve the upstream target for a proxied (non-CONNECT) request.
    static func resolveProxyTarget(_ head: HTTPRequestHead) -> ResolvedTarget? {
        let uri = head.uri
        if let url = URL(string: uri), let scheme = url.scheme, let host = url.host, !host.isEmpty {
            let isSecureScheme = scheme.caseInsensitiveCompare("https") == .orderedSame
                || scheme.caseInsensitiveCompare("wss") == .orderedSame
            let port = url.port ?? (isSecureScheme ? 443 : 80)
            var path = url.path.isEmpty ? "/" : url.path
            if let query = url.query { path += "?" + query }
            return ResolvedTarget(scheme: scheme, host: host, port: port, path: path, isIntercepted: false)
        }
        // Origin-form request: the target comes from the Host header.
        guard let hostHeader = head.headers.first(name: "Host"), !hostHeader.isEmpty else { return nil }
        let (host, port) = parseHostPort(hostHeader, defaultPort: 80)
        return ResolvedTarget(scheme: "http", host: host, port: port, path: uri, isIntercepted: false)
    }

    /// Resolve the tunnel target for a CONNECT request.
    static func resolveConnectTarget(_ authority: String) -> (host: String, port: Int)? {
        let (host, port) = parseHostPort(authority, defaultPort: 443)
        guard !host.isEmpty else { return nil }
        return (host, port)
    }
}
