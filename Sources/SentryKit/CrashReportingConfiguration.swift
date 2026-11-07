import Foundation

/// The two Sentry environments ProxyMaxx reports to.
///
/// One project, one DSN: the environment is a tag on every event, so the same
/// dashboard can separate what testers built locally from what shipped.
public enum CrashReportingEnvironment: String, Sendable, CaseIterable {
    /// Debug builds, `Scripts/run.sh`, and anything not built by the release workflow.
    case development
    /// Release builds made by `.github/workflows/release.yml`.
    case production

    /// The environment a build reports under. It follows the build configuration, so a
    /// locally built `release` binary is `production`, and the release workflow forces
    /// `production` explicitly without relying on that inference.
    public static var current: CrashReportingEnvironment {
        #if DEBUG
        return .development
        #else
        return .production
        #endif
    }
}

/// Where the app finds the Sentry DSN.
///
/// The DSN is a public client identifier, not a credential. It is the same for both
/// environments; the environment is carried separately as the `environment` tag.
/// Release builds receive the DSN from the GitHub Actions `SENTRY_DSN` secret;
/// `Scripts/bundle-app.sh` writes a launcher that exports `SENTRY_DSN`, which is the
/// variable the Sentry SDK itself reads. Local development can export the same
/// variable, or use `PROXYMAXX_SENTRY_DSN`.
public enum CrashReportingConfiguration {
    /// The variable the Sentry SDK reads when `Options` is constructed.
    public static let sdkEnvironmentVariable = "SENTRY_DSN"
    public static let environmentVariable = "PROXYMAXX_SENTRY_DSN"
    /// Optional environment selection, so a locally built release can still report as
    /// `development` while testing. Empty means "follow the build configuration".
    public static let environmentOverrideVariable = "PROXYMAXX_SENTRY_ENVIRONMENT"
    /// Optional fallback, read only when the environment carries nothing.
    public static let infoPlistKey = "SentryDSN"

    public static var dsn: String? {
        firstNonEmpty(processEnvironment[sdkEnvironmentVariable], processEnvironment[environmentVariable])
            ?? firstNonEmpty(Bundle.main.object(forInfoDictionaryKey: infoPlistKey) as? String)
    }

    /// The environment events are tagged with.
    public static var environment: CrashReportingEnvironment {
        if let raw = processEnvironment[environmentOverrideVariable]?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased(),
           let selected = CrashReportingEnvironment(rawValue: raw) {
            return selected
        }
        return .current
    }

    private static let processEnvironment = ProcessInfo.processInfo.environment

    private static func firstNonEmpty(_ values: String?...) -> String? {
        for value in values {
            let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
            if let trimmed, !trimmed.isEmpty { return trimmed }
        }
        return nil
    }
}
