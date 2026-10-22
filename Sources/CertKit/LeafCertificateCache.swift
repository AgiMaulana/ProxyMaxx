import Foundation
import Logging

/// Thread-safe, lazily-populated cache of per-host leaf certificates.
///
/// The proxy asks for a certificate on every TLS handshake; generating a key and
/// signing a certificate each time is wasteful, so results are memoised per host
/// until shortly before they expire.
public actor LeafCertificateCache {
    private let authority: CertificateAuthority
    private let validityDays: Int?
    private let refreshMargin: TimeInterval
    private var certificates: [String: LeafCertificate] = [:]
    private let logger: Logger

    public init(
        authority: CertificateAuthority,
        validityDays: Int? = nil,
        refreshMargin: TimeInterval = 86_400
    ) {
        self.authority = authority
        self.validityDays = validityDays
        self.refreshMargin = refreshMargin
        self.logger = Logger(label: "oss.proxymaxx.certkit.cache")
    }

    /// Return a valid leaf certificate for `host`, generating one if needed.
    public func certificate(forHost host: String) throws -> LeafCertificate {
        let key = Self.normalize(host)
        if let existing = certificates[key], existing.notAfter.timeIntervalSinceNow > refreshMargin {
            return existing
        }
        let leaf = try authority.makeLeafCertificate(forHost: key, validityDays: validityDays)
        certificates[key] = leaf
        logger.debug("issued leaf certificate", metadata: ["host": .string(key)])
        return leaf
    }

    /// Convenience for callers that can tolerate a nil result (e.g. malformed SNI).
    public func certificateIfPossible(forHost host: String) -> LeafCertificate? {
        try? certificate(forHost: host)
    }

    public func removeAll() {
        certificates.removeAll()
    }

    public var count: Int { certificates.count }

    /// Lowercase, strip a trailing dot, and drop any `:port` suffix.
    public static func normalize(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespaces).lowercased()
        if value.hasSuffix(".") { value.removeLast() }
        if let colon = value.lastIndex(of: ":"), !value.hasPrefix("[") {
            // Only strip when the remainder is a port (not part of an IPv6 literal).
            let suffix = value[value.index(after: colon)...]
            if !suffix.isEmpty, suffix.allSatisfy(\.isNumber) {
                value = String(value[..<colon])
            }
        }
        if value.hasPrefix("["), value.hasSuffix("]") {
            value = String(value.dropFirst().dropLast())
        }
        return value
    }
}
