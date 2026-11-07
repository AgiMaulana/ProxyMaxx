import XCTest
import LogKit
import Sentry
@testable import SentryKit

private final class FakeSentryBackend: SentryBackend {
    var startResult = true
    var startCount = 0
    var closeCount = 0
    var options: Options?
    var captures: [(Error, DiagnosticContext?)] = []

    func start(options: Options) -> Bool {
        startCount += 1
        self.options = options
        return startResult
    }

    func close() {
        closeCount += 1
    }

    func capture(error: Error, context: DiagnosticContext?) {
        captures.append((error, context))
    }
}

private struct TestFailure: Error {}

final class CrashReportingServiceTests: XCTestCase {
    private let validDSN = "https://public-key@o1.ingest.sentry.io/1"

    func testDisabledServiceDoesNotInitializeOrCapture() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)

        XCTAssertFalse(service.isEnabled)
        XCTAssertTrue(service.isAvailable)
        service.capture(error: TestFailure(), context: nil)

        XCTAssertEqual(backend.startCount, 0)
        XCTAssertTrue(backend.captures.isEmpty)
    }

    func testMissingDSNNeverEnables() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: nil, backend: backend)

        service.enable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isAvailable)
        XCTAssertEqual(service.lastFailure, .notConfigured)
        XCTAssertEqual(backend.startCount, 0)
    }

    func testInvalidDSNDoesNotStartSDK() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: "not-a-dsn", backend: backend)

        service.enable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.lastFailure, .invalidDSN)
        XCTAssertEqual(backend.startCount, 0)
    }

    func testEnableStartsOnceAndConfiguresPrivacy() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)

        service.enable()
        service.enable()

        XCTAssertTrue(service.isEnabled)
        XCTAssertEqual(backend.startCount, 1)
        let options = backend.options
        XCTAssertNotNil(options)
        XCTAssertEqual(options?.dsn, validDSN)
        XCTAssertEqual(options?.environment, service.environment.rawValue)
        XCTAssertTrue(["development", "production"].contains(options?.environment ?? ""))
        XCTAssertEqual(options?.sendDefaultPii, false)
        XCTAssertEqual(options?.enableAutoSessionTracking, false)
        XCTAssertEqual(options?.enableSwizzling, false)
        XCTAssertEqual(options?.enableNetworkBreadcrumbs, false)
        XCTAssertEqual(options?.enableAutoBreadcrumbTracking, false)
        XCTAssertEqual(options?.enableAutoPerformanceTracing, false)
        XCTAssertEqual(options?.enableCaptureFailedRequests, false)
        XCTAssertEqual(options?.enableWatchdogTerminationTracking, false)
        XCTAssertEqual(options?.enableMemoryIntrospection, false)
        XCTAssertEqual(options?.attachStacktrace, false)
        XCTAssertEqual(options?.maxBreadcrumbs, 0)
    }

    func testStartFailureLeavesServiceDisabled() {
        let backend = FakeSentryBackend()
        backend.startResult = false
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)

        service.enable()

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(service.lastFailure, .sdkRejectedStart)
    }

    func testDisableStopsFutureCaptureAndClosesSDK() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)
        service.enable()
        service.capture(error: TestFailure(), context: nil)
        XCTAssertEqual(backend.captures.count, 1)

        service.disable()
        service.capture(error: TestFailure(), context: nil)

        XCTAssertFalse(service.isEnabled)
        XCTAssertEqual(backend.closeCount, 1)
        XCTAssertEqual(backend.captures.count, 1)
    }

    func testCaptureForwardsOnlyDiagnosticContext() {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)
        service.enable()

        let context = DiagnosticContext(
            component: "ProxyKit.Engine",
            operation: "start",
            errorCode: "bind-failed",
            correlationID: "corr-1",
            message: "failed to bind"
        )
        service.capture(error: TestFailure(), context: context)

        XCTAssertEqual(backend.captures.count, 1)
        XCTAssertEqual(backend.captures.first?.1, context)
    }

    func testNoOpServiceNeverBecomesAvailable() {
        let service = NoOpCrashReportingService()
        service.enable()
        service.capture(error: TestFailure(), context: nil)
        service.disable()
        XCTAssertFalse(service.isEnabled)
        XCTAssertFalse(service.isAvailable)
    }

    func testConsentDefaultsOffAndPersists() throws {
        let suite = "CrashReportingConsentTests-\(UUID().uuidString)"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: suite))
        defer { defaults.removePersistentDomain(forName: suite) }

        XCTAssertFalse(CrashReportingConsent.isEnabled(in: defaults))
        CrashReportingConsent.setEnabled(true, in: defaults)
        XCTAssertTrue(CrashReportingConsent.isEnabled(in: defaults))
        CrashReportingConsent.setEnabled(false, in: defaults)
        XCTAssertFalse(CrashReportingConsent.isEnabled(in: defaults))
    }

    func testConfiguredBeforeSendSanitizesEvents() throws {
        let backend = FakeSentryBackend()
        let service = SentryCrashReportingService(dsn: validDSN, backend: backend)
        service.enable()

        let callback = try XCTUnwrap(backend.options?.beforeSendWithHint)
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Authorization: Bearer abc123")
        let hint = Hint()
        hint.attachments = [Attachment(path: "/tmp/0.log")]

        let sanitized = callback(event, hint)

        XCTAssertNil(hint.attachments.first)
        XCTAssertEqual(sanitized?.message?.formatted, "Authorization: [REDACTED]")
    }
}
