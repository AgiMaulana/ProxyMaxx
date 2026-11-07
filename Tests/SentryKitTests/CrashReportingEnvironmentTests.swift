import XCTest
import LogKit
import Sentry
@testable import SentryKit

final class CrashReportingEnvironmentTests: XCTestCase {
    private let dsn = "https://publickey@o1.ingest.us.sentry.io/4512386169438208"

    func testBothEnvironmentsAreNamedTheWaySentryExpects() {
        XCTAssertEqual(CrashReportingEnvironment.development.rawValue, "development")
        XCTAssertEqual(CrashReportingEnvironment.production.rawValue, "production")
        XCTAssertEqual(CrashReportingEnvironment.allCases.count, 2)
    }

    func testEnvironmentFollowsTheBuildConfiguration() {
        let expected: CrashReportingEnvironment
        #if DEBUG
        expected = .development
        #else
        expected = .production
        #endif
        XCTAssertEqual(CrashReportingEnvironment.current, expected)
        XCTAssertEqual(CrashReportingConfiguration.environment, expected)
    }

    func testDebugBuildsReportAsDevelopment() {
        // The test runner builds the module in debug, so this is the live case.
        #if DEBUG
        XCTAssertEqual(CrashReportingEnvironment.current, .development)
        #endif
    }

    func testEachEnvironmentTagsItsEventsWithoutTouchingTheDSN() throws {
        for environment in CrashReportingEnvironment.allCases {
            let backend = CapturingBackend()
            let service = SentryCrashReportingService(dsn: dsn, environment: environment, backend: backend)
            service.enable()

            let options = try XCTUnwrap(backend.options)
            XCTAssertEqual(options.environment, environment.rawValue)
            XCTAssertEqual(options.dsn, dsn)
            XCTAssertEqual(service.environment, environment)
        }
    }

    /// Environment names are part of what may reach Sentry, so the sanitizer must keep
    /// them and a debug build must not look like a production one.
    func testSanitizedEventKeepsTheEnvironmentTag() throws {
        for environment in CrashReportingEnvironment.allCases {
            let event = Event(level: .error)
            event.environment = environment.rawValue
            event.message = SentryMessage(formatted: "engine failed to start")
            let sanitized = try XCTUnwrap(EventSanitizer().sanitize(event))
            XCTAssertEqual(sanitized.environment, environment.rawValue)
        }
    }

    func testReleaseNameAndDistributionDescribeTheBuild() {
        let backend = CapturingBackend()
        let service = SentryCrashReportingService(
            dsn: dsn,
            environment: .production,
            backend: backend,
            sanitizer: EventSanitizer(),
            releaseName: "com.proxymaxx.app@0.1.0",
            distribution: "42"
        )
        service.enable()

        XCTAssertEqual(backend.options?.releaseName, "com.proxymaxx.app@0.1.0")
        XCTAssertEqual(backend.options?.dist, "42")
        XCTAssertEqual(backend.options?.environment, "production")
    }
}

private final class CapturingBackend: SentryBackend {
    private(set) var options: Options?

    func start(options: Options) -> Bool {
        self.options = options
        return true
    }

    func close() {}
    func capture(error: Error, context: DiagnosticContext?) {}
}
