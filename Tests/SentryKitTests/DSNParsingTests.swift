import XCTest
import Sentry
@testable import SentryKit

final class DSNParsingTests: XCTestCase {
    /// The shape of the public DSN used for release builds: a public key, the US
    /// ingestion host, and the numeric project path. It reaches the app through the
    /// `SENTRY_DSN` environment variable, so the SDK must parse it unchanged.
    func testIngestionStyleDSNIsAccepted() throws {
        let dsn = "https://publickey@o1.ingest.us.sentry.io/4512386169438208"
        let options = Options()
        options.dsn = dsn
        let parsed = try XCTUnwrap(options.parsedDsn)
        XCTAssertNotNil(parsed)
        XCTAssertEqual(options.dsn, dsn)
    }

    /// The parsed DSN is what decides where an envelope goes. Deriving the base URL
    /// from the DSN itself must keep the ingestion host and drop the key, because
    /// the key travels in the `X-Sentry-Auth` header instead.
    func testBaseURLDropsThePublicKeyAndKeepsTheHost() throws {
        let dsn = "https://publickey@o4511259029340160.ingest.us.sentry.io/4512386169438208"
        var components = try XCTUnwrap(URLComponents(string: dsn))
        components.user = nil
        components.password = nil
        let base = try XCTUnwrap(components.url)
        XCTAssertEqual(base.absoluteString, "https://o4511259029340160.ingest.us.sentry.io/4512386169438208")
    }

    func testMalformedDSNIsRejected() {
        let options = Options()
        options.dsn = "not-a-dsn"
        XCTAssertNil(options.parsedDsn)
        XCTAssertNil(options.dsn)
    }
}
