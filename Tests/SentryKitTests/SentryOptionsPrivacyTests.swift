import XCTest
import LogKit
import Sentry
@testable import SentryKit

/// Checks against the real SDK, in as far as it can be inspected without a network.
/// These guard the one thing the abstraction cannot: that the configured options make
/// the SDK drop event classes ProxyMaxx never wants to send.
final class SentryOptionsPrivacyTests: XCTestCase {
    private func configuredOptions() throws -> Options {
        let backend = RecordingBackend()
        let service = SentryCrashReportingService(
            dsn: "https://publickey@o1.ingest.us.sentry.io/4512386169438208",
            backend: backend
        )
        service.enable()
        return try XCTUnwrap(backend.options)
    }

    /// `Options()` reads `SENTRY_DSN` from the environment itself. A disabled service
    /// never builds one, which is what keeps a stray variable from starting reporting.
    func testWithoutADSNAndConsentNoOptionsAreBuilt() {
        let backend = RecordingBackend()
        let service = SentryCrashReportingService(dsn: nil, backend: backend)
        service.enable()
        XCTAssertNil(backend.options)
        XCTAssertFalse(service.isEnabled)
    }

    func testCrashHandlerStaysOnSoConsentedCrashesAreReported() {
        guard let options = try? configuredOptions() else { return XCTFail("no options") }
        // The one integration kept: it is installed by start, which only runs after consent.
        XCTAssertTrue(options.enableCrashHandler)
        XCTAssertTrue(options.enabled)
    }

    func testBreadcrumbCallbacksRejectEverything() {
        guard let options = try? configuredOptions() else { return XCTFail("no options") }
        let breadcrumb = Breadcrumb(level: .info, category: "http")
        breadcrumb.message = "GET https://example.com/private"
        XCTAssertNil(options.beforeBreadcrumb?(breadcrumb))
    }

    func testBeforeSendDropsAttachmentsAndSanitizes() {
        guard let options = try? configuredOptions() else { return XCTFail("no options") }
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Cookie: session=abc")
        let hint = Hint()
        hint.attachments = [Attachment(path: "/tmp/0.log")]
        hint.urlRequest = URLRequest(url: URL(string: "https://example.com/x?access_token=abc")!)

        let sanitized = options.beforeSendWithHint?(event, hint)

        XCTAssertNil(hint.attachments.first)
        XCTAssertNil(sanitized?.request)
        XCTAssertEqual(sanitized?.message?.formatted, "Cookie: [REDACTED]")
    }

    /// The SDK serializes the scope into every event. The configured scope must carry
    /// no identity and no breadcrumbs, whatever the application put on a scope earlier.
    func testConfiguredScopeSerializesWithoutIdentityOrBreadcrumbs() throws {
        guard let options = try? configuredOptions() else { return XCTFail("no options") }
        let scope = Scope()
        let user = User()
        user.email = "alice@example.com"
        scope.setUser(user)
        scope.addBreadcrumb(Breadcrumb(level: .info, category: "http"))

        let prepared = options.initialScope(scope)
        let serialized = try XCTUnwrap(prepared.serialize() as? [String: Any])

        XCTAssertNil(serialized["user"])
        XCTAssertNil(serialized["breadcrumbs"])
    }
}

/// Captures the options a service hands to the SDK, and nothing else.
private final class RecordingBackend: SentryBackend {
    private(set) var options: Options?

    func start(options: Options) -> Bool {
        self.options = options
        return true
    }

    func close() {}
    func capture(error: Error, context: DiagnosticContext?) {}
}
