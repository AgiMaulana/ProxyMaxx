import Foundation
import NIOSSL
import NIOCore
import CertKit
import Logging

/// Builds and caches the `NIOSSLContext` used to terminate TLS for each MITM host.
///
/// Constructing an `NIOSSLContext` involves parsing the certificate chain and key,
/// so results are memoised per host alongside the leaf certificates themselves.
actor MITMContextCache {
    private let leafCache: LeafCertificateCache
    private let minimumTLSVersion: TLSVersion
    private var contexts: [String: NIOSSLContext] = [:]
    private let logger: Logger

    init(leafCache: LeafCertificateCache, minimumTLSVersion: TLSVersion = .tlsv12) {
        self.leafCache = leafCache
        self.minimumTLSVersion = minimumTLSVersion
        self.logger = Logger(label: "oss.proxymaxx.proxykit.mitm-context")
    }

    /// Return a server-side TLS context presenting a leaf certificate for `host`.
    func context(forHost host: String) async throws -> NIOSSLContext {
        let key = LeafCertificateCache.normalize(host)
        if let existing = contexts[key] {
            return existing
        }
        let leaf = try await leafCache.certificate(forHost: key)
        let context = try Self.makeServerContext(for: leaf, minimumTLSVersion: minimumTLSVersion)
        contexts[key] = context
        logger.debug("built MITM TLS context", metadata: ["host": .string(key)])
        return context
    }

    func removeAll() {
        contexts.removeAll()
    }

    private static func makeServerContext(for leaf: LeafCertificate, minimumTLSVersion: TLSVersion) throws -> NIOSSLContext {
        do {
            let certificates = try NIOSSLCertificate.fromPEMBytes(Array(leaf.certificatePEM.utf8))
            let privateKey = try NIOSSLPrivateKey(bytes: Array(leaf.privateKeyPEM.utf8), format: .pem)
            var configuration = TLSConfiguration.makeServerConfiguration(
                certificateChain: certificates.map { .certificate($0) },
                privateKey: .privateKey(privateKey)
            )
            configuration.minimumTLSVersion = minimumTLSVersion
            return try NIOSSLContext(configuration: configuration)
        } catch {
            throw ProxyKitError.tlsSetup("\(error)")
        }
    }
}
