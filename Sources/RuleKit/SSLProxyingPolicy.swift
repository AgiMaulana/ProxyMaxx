import Foundation

/// Decides whether a host's TLS traffic should be decrypted (MITM'd) or tunnelled opaquely.
///
/// Mirrors ProxyMaxx's SSL Proxying list: an optional include list of wildcard patterns and an
/// exclude list that always wins. An empty include list means "decrypt everything not excluded".
public struct SSLProxyingPolicy: Sendable, Equatable, Codable {
    public var include: [String]
    public var exclude: [String]

    public init(include: [String] = [], exclude: [String] = []) {
        self.include = include
        self.exclude = exclude
    }

    /// Decrypt everything except the excluded patterns.
    public static let decryptAll = SSLProxyingPolicy()

    public func shouldDecrypt(host: String) -> Bool {
        let host = Self.normalize(host)
        if exclude.contains(where: { Wildcard.matches(pattern: $0, value: host) }) {
            return false
        }
        if include.isEmpty {
            return true
        }
        return include.contains(where: { Wildcard.matches(pattern: $0, value: host) })
    }

    static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
