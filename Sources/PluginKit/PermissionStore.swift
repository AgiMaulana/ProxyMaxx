import Foundation
import Crypto
import Branding

/// A permission decision state (docs/plugin-store-phase1.md §8.3). Raw values match
/// the SDK's status vocabulary, so the runner's JSON responses need no translation.
public enum PluginPermissionStatus: String, Codable, Sendable {
    case granted = "GRANTED"
    case denied = "DENIED"
    case notRequested = "NOT_REQUESTED"
    case unavailable = "UNAVAILABLE"
}

/// One recorded decision: the status and when the user made it.
public struct PluginPermissionDecision: Codable, Equatable, Sendable {
    public var status: PluginPermissionStatus
    public var decidedAt: Date

    public init(status: PluginPermissionStatus, decidedAt: Date = Date()) {
        self.status = status
        self.decidedAt = decidedAt
    }
}

/// On-disk shape for `permissions.json`: the decision payload plus an HMAC so
/// modification outside ProxyMaxx is detectable (docs §9, "Protect permission state
/// against unauthorized modification"). The HMAC key lives in the login Keychain.
struct PermissionEnvelope: Codable {
    var payload: Data
    var mac: Data
}

/// Persists permission decisions, keyed by stable plugin id, across restarts.
///
/// Decisions and declarations are kept apart: this store holds only user decisions;
/// what a plugin declares lives in its manifest. The file is written 0600 and every
/// write is re-signed, so a read that fails verification sets `integrityError` and
/// the store then refuses to report any grant — fail closed (docs §9, §10). The
/// tampered file is kept for inspection; the next successful `record` re-establishes
/// integrity from the current in-memory state.
@MainActor
public final class PermissionStore: ObservableObject {
    /// Keychain account holding the 32-byte HMAC key.
    static let integrityAccount = "permission-integrity"

    @Published public private(set) var integrityError: String?

    private var decisions: [String: [String: PluginPermissionDecision]] = [:]
    private let url: URL
    private let secrets: SecretProviding
    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated static var defaultURL: URL {
        Brand.supportDirectory
            .appendingPathComponent("plugins", isDirectory: true)
            .appendingPathComponent("permissions.json")
    }

    public init(url: URL = PermissionStore.defaultURL, secrets: SecretProviding = KeychainSecretStore()) {
        self.url = url
        self.secrets = secrets
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.encoder = encoder
        self.decoder = decoder
        load()
    }

    /// The current decision for a permission, or `notRequested` when none exists.
    /// While integrity cannot be verified, nothing is reported as granted.
    public func status(pluginID: String, permissionID: String) -> PluginPermissionStatus {
        guard integrityError == nil else { return .notRequested }
        return decisions[pluginID]?[permissionID]?.status ?? .notRequested
    }

    /// The recorded decision with its timestamp, when one exists.
    public func decision(pluginID: String, permissionID: String) -> PluginPermissionDecision? {
        guard integrityError == nil else { return nil }
        return decisions[pluginID]?[permissionID]
    }

    public func record(pluginID: String, permissionID: String, status: PluginPermissionStatus, decidedAt: Date = Date()) throws {
        var perPlugin = decisions[pluginID] ?? [:]
        perPlugin[permissionID] = PluginPermissionDecision(status: status, decidedAt: decidedAt)
        decisions[pluginID] = perPlugin
        integrityError = nil
        try persist()
    }

    /// Drop every decision belonging to one plugin. Used by uninstall (docs §5.4).
    public func removeDecisions(pluginID: String) throws {
        guard decisions.removeValue(forKey: pluginID) != nil else { return }
        try persist()
    }

    /// True when decisions can be trusted for authorization right now.
    public var isTrustworthy: Bool { integrityError == nil }

    private func load() {
        guard let data = try? Data(contentsOf: url) else { return } // Missing file = fresh state.
        do {
            let key = try Self.integrityKey(using: secrets)
            let envelope = try decoder.decode(PermissionEnvelope.self, from: data)
            guard HMAC<SHA256>.isValidAuthenticationCode(envelope.mac, authenticating: envelope.payload, using: SymmetricKey(data: key)) else {
                throw PluginPermissionError.integrityFailure
            }
            decisions = try decoder.decode([String: [String: PluginPermissionDecision]].self, from: envelope.payload)
        } catch {
            decisions = [:]
            integrityError = "Permission state could not be verified (\(error.localizedDescription)). Protected operations are denied until it is re-established."
        }
    }

    private func persist() throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let payload = try encoder.encode(decisions)
        let key = try Self.integrityKey(using: secrets)
        let mac = HMAC<SHA256>.authenticationCode(for: payload, using: SymmetricKey(data: key))
        let envelope = try encoder.encode(PermissionEnvelope(payload: payload, mac: Data(mac)))
        try envelope.write(to: url, options: .atomic)
        // Match the CA private-key precedent: decisions are protected user state.
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }

    /// The 32-byte HMAC key, generated on first use and kept in the Keychain.
    static func integrityKey(using secrets: SecretProviding) throws -> Data {
        if let existing = try secrets.data(forKey: integrityAccount), existing.count == 32 {
            return existing
        }
        var key = Data(count: 32)
        let status = key.withUnsafeMutableBytes { buffer in
            SecRandomCopyBytes(kSecRandomDefault, 32, buffer.baseAddress!)
        }
        guard status == errSecSuccess else {
            throw PluginPermissionError.storageFailed("Could not generate the permission-state integrity key (\(status)).")
        }
        try secrets.store(key, forKey: integrityAccount)
        return key
    }
}
