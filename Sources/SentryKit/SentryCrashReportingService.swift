import Foundation
import LogKit
import Sentry

/// Consent-controlled Sentry integration.
///
/// The SDK is not initialized until `enable()` is called, and ProxyMaxx only calls that
/// after reading the user's explicit preference. Disabling stops captures immediately,
/// closes the SDK (which flushes what the SDK permits), and leaves local logging alone.
public final class SentryCrashReportingService: CrashReportingService {
    public enum Failure: Equatable {
        case notConfigured
        case invalidDSN
        case sdkRejectedStart
    }

    private let dsn: String?
    /// The Sentry environment every event from this process is tagged with.
    public let environment: CrashReportingEnvironment
    private let backend: SentryBackend
    private let sanitizer: EventSanitizer
    private let releaseName: String?
    private let distribution: String?
    private let lock = NSLock()
    private var started = false

    public private(set) var lastFailure: Failure?

    public convenience init(
        dsn: String?,
        environment: CrashReportingEnvironment = .current,
        backend: SentryBackend = SentrySDKBackend(),
        sanitizer: EventSanitizer = EventSanitizer()
    ) {
        self.init(
            dsn: dsn,
            environment: environment,
            backend: backend,
            sanitizer: sanitizer,
            releaseName: Self.releaseName,
            distribution: Self.buildNumber
        )
    }

    /// The injectable initializer. Tests use it to pin a release name without depending
    /// on the test runner's bundle.
    init(
        dsn: String?,
        environment: CrashReportingEnvironment,
        backend: SentryBackend,
        sanitizer: EventSanitizer,
        releaseName: String?,
        distribution: String?
    ) {
        let trimmed = dsn?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.dsn = (trimmed?.isEmpty ?? true) ? nil : trimmed
        self.environment = environment
        self.backend = backend
        self.sanitizer = sanitizer
        self.releaseName = releaseName
        self.distribution = distribution
    }

    public var isAvailable: Bool { dsn != nil }

    public var isEnabled: Bool {
        lock.lock(); defer { lock.unlock() }
        return started
    }

    public func enable() {
        lock.lock()
        guard !started else { lock.unlock(); return }
        guard let dsn else {
            lastFailure = .notConfigured
            lock.unlock()
            return
        }
        let options = makeOptions(dsn: dsn)
        guard options.dsn != nil else {
            lastFailure = .invalidDSN
            lock.unlock()
            return
        }
        started = true
        lastFailure = nil
        lock.unlock()

        if !backend.start(options: options) {
            lock.lock()
            started = false
            lastFailure = .sdkRejectedStart
            lock.unlock()
        }
    }

    public func disable() {
        lock.lock()
        guard started else { lock.unlock(); return }
        started = false
        lock.unlock()
        backend.close()
    }

    public func capture(error: Error, context: DiagnosticContext?) {
        lock.lock()
        let active = started
        lock.unlock()
        guard active else { return }
        backend.capture(error: error, context: context)
    }

    // MARK: - SDK configuration

    private func makeOptions(dsn: String) -> Options {
        let options = Options()
        options.dsn = dsn
        options.environment = environment.rawValue
        options.releaseName = releaseName
        options.dist = distribution

        // Nothing is collected automatically. Crash handlers are the one integration
        // kept: they are installed by `start`, which only runs after consent.
        options.debug = false
        options.enabled = true
        options.sendDefaultPii = false
        options.enableAutoSessionTracking = false
        options.enableAutoBreadcrumbTracking = false
        options.enableNetworkBreadcrumbs = false
        options.enableSwizzling = false
        options.enableAutoPerformanceTracing = false
        options.enableCaptureFailedRequests = false
        options.enableCoreDataTracing = false
        options.enableDataSwizzling = false
        options.enableFileIOTracing = false
        options.enableFileManagerSwizzling = false
        options.enableNetworkTracking = false
        options.enableAppHangTracking = false
        options.enableMetricKit = false
        options.enableMetricKitRawPayload = false
        options.enableWatchdogTerminationTracking = false
        options.enableMemoryIntrospection = false
        options.enableGraphQLOperationTracking = false
        options.enablePersistingTracesWhenCrashing = false
        options.attachStacktrace = false
        options.attachAllThreads = false
        options.maxBreadcrumbs = 0
        options.beforeBreadcrumb = { _ in nil }
        options.beforeSendWithHint = { [sanitizer] event, hint in
            // ProxyMaxx never attaches logs, screenshots, or captured traffic. Clear
            // anything the SDK or an integration may have added anyway.
            hint.attachments = []
            return sanitizer.sanitize(event)
        }
        options.initialScope = { scope in
            scope.clearBreadcrumbs()
            scope.clearAttachments()
            scope.setUser(nil)
            return scope
        }
        return options
    }

    private static var releaseName: String? {
        let info = Bundle.main.infoDictionary
        guard let version = info?["CFBundleShortVersionString"] as? String, !version.isEmpty else {
            return nil
        }
        let identifier = info?["CFBundleIdentifier"] as? String ?? "proxymaxx"
        return "\(identifier)@\(version)"
    }

    private static var buildNumber: String? {
        let value = Bundle.main.infoDictionary?["CFBundleVersion"] as? String
        return (value?.isEmpty ?? true) ? nil : value
    }
}
