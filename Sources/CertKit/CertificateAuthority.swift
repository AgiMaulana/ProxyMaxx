import Foundation
import Darwin
import X509
import SwiftASN1
import Crypto
import Logging

public enum CertKitError: Error, CustomStringConvertible {
    case invalidPEM(String)
    case unsupportedHost(String)
    case encoding(String)

    public var description: String {
        switch self {
        case .invalidPEM(let detail):
            return "Invalid certificate material: \(detail)"
        case .unsupportedHost(let host):
            return "Cannot build a certificate for host \"\(host)\""
        case .encoding(let detail):
            return "Failed to encode certificate: \(detail)"
        }
    }
}

/// Serialise a certificate to DER using the SwiftASN1 serializer.
func derEncode(_ certificate: Certificate) throws -> Data {
    var serializer = DER.Serializer()
    do {
        try serializer.serialize(certificate)
    } catch {
        throw CertKitError.encoding("\(error)")
    }
    return Data(serializer.serializedBytes)
}

/// A generated leaf certificate and its private key, ready to be presented by the proxy.
public struct LeafCertificate: Sendable {
    public let host: String
    public let certificate: Certificate
    public let privateKey: P256.Signing.PrivateKey
    public let notBefore: Date
    public let notAfter: Date
    private let pem: String
    private let der: Data

    init(host: String, certificate: Certificate, privateKey: P256.Signing.PrivateKey, notBefore: Date, notAfter: Date, pem: String, der: Data) {
        self.host = host
        self.certificate = certificate
        self.privateKey = privateKey
        self.notBefore = notBefore
        self.notAfter = notAfter
        self.pem = pem
        self.der = der
    }

    public var certificatePEM: String { pem }
    public var privateKeyPEM: String { privateKey.pemRepresentation }
    public var certificateDER: Data { der }

    public func isValid(at date: Date = Date()) -> Bool {
        date >= notBefore && date < notAfter
    }
}

/// A local root certificate authority used to sign per-host leaf certificates for MITM.
///
/// The CA key never leaves the process; leaves are generated on demand and cached
/// by `LeafCertificateCache`.
public final class CertificateAuthority: @unchecked Sendable {
    public let certificate: Certificate
    public let privateKey: P256.Signing.PrivateKey
    public let commonName: String
    private let authorityKeyIdentifier: ArraySlice<UInt8>
    private let pem: String
    private let der: Data

    /// Generate a brand-new self-signed root CA.
    public init(
        commonName: String = "ProxyMaxx Root CA",
        organization: String = "ProxyMaxx",
        validityDays: Int = 3650
    ) throws {
        let key = P256.Signing.PrivateKey()
        let publicKey = Certificate.PublicKey(key.publicKey)
        let subject = try DistinguishedName {
            CommonName(commonName)
            OrganizationName(organization)
        }
        let now = Date()
        let certificate = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: now.addingTimeInterval(-3600),
            notValidAfter: now.addingTimeInterval(TimeInterval(validityDays) * 86_400),
            issuer: subject,
            subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.isCertificateAuthority(maxPathLength: 0))
                Critical(KeyUsage(digitalSignature: true, keyCertSign: true, cRLSign: true))
                SubjectKeyIdentifier(hash: publicKey)
            },
            issuerPrivateKey: Certificate.PrivateKey(key)
        )
        self.certificate = certificate
        self.privateKey = key
        self.commonName = commonName
        self.authorityKeyIdentifier = SubjectKeyIdentifier(hash: publicKey).keyIdentifier
        self.pem = try certificate.serializeAsPEM().pemString
        self.der = try derEncode(certificate)
    }

    /// Restore a CA from PEM-encoded certificate and private key.
    public init(pemCertificate: String, pemPrivateKey: String, commonName: String = "ProxyMaxx Root CA") throws {
        let certificate: Certificate
        do {
            certificate = try Certificate(pemEncoded: pemCertificate)
        } catch {
            throw CertKitError.invalidPEM("certificate: \(error)")
        }
        let key: P256.Signing.PrivateKey
        do {
            key = try P256.Signing.PrivateKey(pemRepresentation: pemPrivateKey)
        } catch {
            throw CertKitError.invalidPEM("private key: \(error)")
        }
        self.certificate = certificate
        self.privateKey = key
        self.commonName = commonName
        self.authorityKeyIdentifier = SubjectKeyIdentifier(hash: Certificate.PublicKey(key.publicKey)).keyIdentifier
        self.pem = try certificate.serializeAsPEM().pemString
        self.der = try derEncode(certificate)
    }

    public var certificatePEM: String { pem }
    public var privateKeyPEM: String { privateKey.pemRepresentation }
    public var certificateDER: Data { der }

    /// Colon-separated SHA-256 fingerprint of the DER-encoded certificate.
    public var sha256Fingerprint: String {
        SHA256.hash(data: der)
            .map { String(format: "%02X", $0) }
            .enumerated()
            .map { $0.offset % 2 == 0 && $0.offset > 0 ? ":\($0.element)" : $0.element }
            .joined()
    }

    /// Certificate chain to present to clients (leaf only — the root is trusted locally).
    public var chainPEM: String { pem }

    /// Chromium rejects a leaf whose lifetime exceeds its limit for the date the leaf was issued
    /// with `ERR_CERT_VALIDITY_TOO_LONG`, which WebView reports as an invalid certificate and
    /// renders as a blank page. The limit applies whenever Chromium classifies the root as
    /// publicly trusted, and a root in the Android system store counts as that — so the failure
    /// only shows up after the CA is installed as a system certificate, while Java-based clients,
    /// which do not apply the cap, keep accepting the same chain.
    ///
    /// The schedule mirrors `CertVerifyProc::HasTooLongValidity` in Chromium's
    /// `net/cert/cert_verify_proc.cc`, which follows the CA/Browser Forum reduction of publicly
    /// trusted lifetimes.
    ///
    /// - Parameter issueDate: The certificate's `notValidBefore` instant.
    public static func maximumLeafValidityDays(issuedOn issueDate: Date) -> Int {
        if issueDate >= utcDate(year: 2029, month: 3, day: 15) { return 47 }
        if issueDate >= utcDate(year: 2027, month: 3, day: 15) { return 100 }
        if issueDate >= utcDate(year: 2026, month: 3, day: 15) { return 200 }
        return 398
    }

    private static func utcDate(year: Int, month: Int, day: Int) -> Date {
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components) ?? .distantPast
    }

    /// Generate a leaf certificate for `host`.
    ///
    /// `validityDays` defaults to the longest lifetime Chromium accepts for a leaf issued now.
    public func makeLeafCertificate(
        forHost host: String,
        validityDays: Int? = nil
    ) throws -> LeafCertificate {
        let key = P256.Signing.PrivateKey()
        let publicKey = Certificate.PublicKey(key.publicKey)
        let subject = try DistinguishedName { CommonName(host) }
        let names = Self.subjectAlternativeNames(forHost: host)
        guard !names.isEmpty else { throw CertKitError.unsupportedHost(host) }

        let now = Date()
        let notBefore = now.addingTimeInterval(-3600)
        let effectiveValidityDays = validityDays ?? Self.maximumLeafValidityDays(issuedOn: notBefore)
        // Measure the lifetime from `notBefore` so the hour of backdating stays inside the
        // allowed span; Chromium computes the span the same way.
        let notAfter = notBefore.addingTimeInterval(TimeInterval(effectiveValidityDays) * 86_400)

        let leaf = try Certificate(
            version: .v3,
            serialNumber: Certificate.SerialNumber(),
            publicKey: publicKey,
            notValidBefore: notBefore,
            notValidAfter: notAfter,
            issuer: certificate.subject,
            subject: subject,
            extensions: try Certificate.Extensions {
                Critical(BasicConstraints.notCertificateAuthority)
                Critical(KeyUsage(digitalSignature: true, keyEncipherment: true))
                try ExtendedKeyUsage([.serverAuth])
                SubjectAlternativeNames(names)
                SubjectKeyIdentifier(hash: publicKey)
                AuthorityKeyIdentifier(keyIdentifier: authorityKeyIdentifier)
            },
            issuerPrivateKey: Certificate.PrivateKey(privateKey)
        )

        return LeafCertificate(
            host: host,
            certificate: leaf,
            privateKey: key,
            notBefore: notBefore,
            notAfter: notAfter,
            pem: try leaf.serializeAsPEM().pemString,
            der: try derEncode(leaf)
        )
    }

    /// Build SAN entries for a host that may be a DNS name, wildcard, or IP literal.
    static func subjectAlternativeNames(forHost host: String) -> [GeneralName] {
        let trimmed = host.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmed.isEmpty else { return [] }
        if let bytes = ipAddressBytes(trimmed) {
            return [.ipAddress(ASN1OctetString(contentBytes: bytes[...]))]
        }
        return [.dnsName(trimmed)]
    }

    /// Parse an IPv4 or IPv6 literal into its network-order bytes, or nil for DNS names.
    static func ipAddressBytes(_ host: String) -> [UInt8]? {
        var v4 = in_addr()
        if inet_pton(AF_INET, host, &v4) == 1 {
            return withUnsafeBytes(of: v4) { Array($0) }
        }
        var v6 = in6_addr()
        if inet_pton(AF_INET6, host, &v6) == 1 {
            return withUnsafeBytes(of: v6) { Array($0) }
        }
        return nil
    }
}
