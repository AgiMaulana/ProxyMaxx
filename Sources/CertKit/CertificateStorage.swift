import Foundation
import Branding

/// Persists the root CA and exports installable certificate files.
public enum CertificateStorage {
    public static let certificateFileName = "proxymaxx-ca.crt"
    public static let privateKeyFileName = "proxymaxx-ca.key"
    public static let derFileName = "proxymaxx-ca.cer"

    /// `~/Library/Application Support/ProxyMaxx/certs`
    public static var defaultDirectory: URL {
        Brand.supportDirectory.appendingPathComponent("certs", isDirectory: true)
    }

    /// Load an existing CA from `directory`, or generate and persist a new one.
    @discardableResult
    public static func loadOrCreate(at directory: URL = defaultDirectory, commonName: String = "ProxyMaxx Root CA") throws -> CertificateAuthority {
        if let existing = try? load(from: directory) {
            return existing
        }
        let authority = try CertificateAuthority(commonName: commonName)
        try save(authority, to: directory)
        return authority
    }

    public static func load(from directory: URL = defaultDirectory) throws -> CertificateAuthority {
        let certificateURL = directory.appendingPathComponent(certificateFileName)
        let keyURL = directory.appendingPathComponent(privateKeyFileName)
        let certificatePEM = try String(contentsOf: certificateURL, encoding: .utf8)
        let keyPEM = try String(contentsOf: keyURL, encoding: .utf8)
        return try CertificateAuthority(pemCertificate: certificatePEM, pemPrivateKey: keyPEM)
    }

    public static func save(_ authority: CertificateAuthority, to directory: URL = defaultDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try authority.certificatePEM.write(to: directory.appendingPathComponent(certificateFileName), atomically: true, encoding: .utf8)
        try authority.privateKeyPEM.write(to: directory.appendingPathComponent(privateKeyFileName), atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: directory.appendingPathComponent(privateKeyFileName).path)
        try authority.certificateDER.write(to: directory.appendingPathComponent(derFileName), options: .atomic)
    }

    /// Export a DER-encoded `.cer` suitable for `security add-trusted-cert`.
    public static func exportDER(_ authority: CertificateAuthority, to url: URL) throws {
        try authority.certificateDER.write(to: url, options: .atomic)
    }

    /// Export a PEM-encoded `.crt` suitable for manual trust installation.
    public static func exportPEM(_ authority: CertificateAuthority, to url: URL) throws {
        try authority.certificatePEM.write(to: url, atomically: true, encoding: .utf8)
    }
}
