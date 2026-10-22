import XCTest
import Security
@testable import CertKit

final class CertKitTests: XCTestCase {
    func testRootCAHasPEMAndDER() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        XCTAssertTrue(ca.certificatePEM.contains("BEGIN CERTIFICATE"))
        XCTAssertFalse(ca.certificateDER.isEmpty)
        XCTAssertTrue(ca.privateKeyPEM.contains("BEGIN PRIVATE KEY"))
    }

    func testLeafIsTrustedForHostBySecTrust() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let leaf = try ca.makeLeafCertificate(forHost: "example.com")
        XCTAssertTrue(validate(ca: ca, leaf: leaf, host: "example.com"), "leaf should chain to the CA for example.com")
    }

    func testLeafIsTrustedForIPAddress() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let leaf = try ca.makeLeafCertificate(forHost: "127.0.0.1")
        XCTAssertTrue(validate(ca: ca, leaf: leaf, host: "127.0.0.1"), "leaf should chain to the CA for an IP SAN")
    }

    func testLeafIsRejectedForOtherHost() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let leaf = try ca.makeLeafCertificate(forHost: "example.com")
        XCTAssertFalse(validate(ca: ca, leaf: leaf, host: "evil.example"), "SAN must not cover an unrelated host")
    }

    func testRoundTripThroughPEM() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let restored = try CertificateAuthority(pemCertificate: ca.certificatePEM, pemPrivateKey: ca.privateKeyPEM)
        let leaf = try restored.makeLeafCertificate(forHost: "api.example.com")
        XCTAssertTrue(validate(ca: ca, leaf: leaf, host: "api.example.com"))
    }

    func testCacheReturnsSameCertificate() async throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let cache = LeafCertificateCache(authority: ca)
        let first = try await cache.certificate(forHost: "Example.com:443")
        let second = try await cache.certificate(forHost: "example.com")
        XCTAssertEqual(first.certificateDER, second.certificateDER, "host normalisation should share one certificate")
        let count = await cache.count
        XCTAssertEqual(count, 1)
    }

    func testLeafValidityFollowsChromiumLifetimeSchedule() throws {
        let cases: [(issued: DateComponents, expectedDays: Int)] = [
            (DateComponents(year: 2026, month: 3, day: 14), 398),
            (DateComponents(year: 2026, month: 3, day: 15), 200),
            (DateComponents(year: 2027, month: 3, day: 14), 200),
            (DateComponents(year: 2027, month: 3, day: 15), 100),
            (DateComponents(year: 2029, month: 3, day: 14), 100),
            (DateComponents(year: 2029, month: 3, day: 15), 47)
        ]
        for testCase in cases {
            let issued = try XCTUnwrap(utcDate(testCase.issued))
            XCTAssertEqual(
                CertificateAuthority.maximumLeafValidityDays(issuedOn: issued),
                testCase.expectedDays,
                "lifetime for a leaf issued on \(issued)"
            )
        }
    }

    func testLeafLifetimeStaysWithinTheChromiumLimit() throws {
        let ca = try CertificateAuthority(commonName: "ProxyMaxx Test CA")
        let leaf = try ca.makeLeafCertificate(forHost: "example.com")
        let lifetimeInDays = leaf.notAfter.timeIntervalSince(leaf.notBefore) / 86_400
        let allowedDays = CertificateAuthority.maximumLeafValidityDays(issuedOn: leaf.notBefore)
        XCTAssertLessThanOrEqual(
            lifetimeInDays,
            Double(allowedDays),
            "Chromium rejects this chain with ERR_CERT_VALIDITY_TOO_LONG once the CA is a system root"
        )
    }

    // MARK: - Helpers

    private func utcDate(_ components: DateComponents) -> Date? {
        var components = components
        components.timeZone = TimeZone(secondsFromGMT: 0)
        return Calendar(identifier: .gregorian).date(from: components)
    }

    private func secCertificate(_ der: Data) -> SecCertificate? {
        SecCertificateCreateWithData(nil, der as CFData)
    }

    private func validate(ca: CertificateAuthority, leaf: LeafCertificate, host: String) -> Bool {
        guard let anchor = secCertificate(ca.certificateDER), let leafCert = secCertificate(leaf.certificateDER) else {
            return false
        }
        var trust: SecTrust?
        let policy = SecPolicyCreateSSL(true, host as CFString)
        guard SecTrustCreateWithCertificates(leafCert, policy, &trust) == errSecSuccess, let trust else {
            return false
        }
        SecTrustSetAnchorCertificates(trust, [anchor] as CFArray)
        SecTrustSetAnchorCertificatesOnly(trust, true)
        var error: CFError?
        return SecTrustEvaluateWithError(trust, &error)
    }
}
