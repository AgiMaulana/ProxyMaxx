import Foundation

/// Remote crash reporting, kept behind an abstraction so the rest of ProxyMaxx
/// never imports or configures the Sentry SDK directly.
public protocol CrashReportingService: AnyObject {
    /// True only while a consented, configured reporter is active.
    var isEnabled: Bool { get }
    /// True when this build has a usable DSN. An unavailable service can never
    /// be enabled, and the settings UI says so rather than silently doing nothing.
    var isAvailable: Bool { get }
    func enable()
    func disable()
    func capture(error: Error, context: DiagnosticContext?)
}

/// The implementation used before consent, in tests, and in builds without a DSN.
public final class NoOpCrashReportingService: CrashReportingService {
    public init() {}
    public var isEnabled: Bool { false }
    public var isAvailable: Bool { false }
    public func enable() {}
    public func disable() {}
    public func capture(error: Error, context: DiagnosticContext?) {}
}

/// Persisted consent for remote error reporting. Off unless the user turned it on.
public enum CrashReportingConsent {
    public static let defaultsKey = "ProxyMaxxErrorReportingEnabled"
    /// Set once the user answered the first-launch prompt with "Don't ask again".
    /// Enabling reporting from Settings means no prompt is due any more either.
    public static let askedDefaultsKey = "ProxyMaxxErrorReportingAsked"

    public static func isEnabled(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: defaultsKey)
    }

    public static func setEnabled(_ enabled: Bool, in defaults: UserDefaults = .standard) {
        defaults.set(enabled, forKey: defaultsKey)
        // Enabling is itself an answer, so a later launch must not ask again.
        if enabled {
            setAsked(in: defaults)
        }
    }

    public static func wasAsked(in defaults: UserDefaults = .standard) -> Bool {
        defaults.bool(forKey: askedDefaultsKey)
    }

    public static func setAsked(in defaults: UserDefaults = .standard) {
        defaults.set(true, forKey: askedDefaultsKey)
    }

    /// Whether the prompt is still owed: only while the choice is open. Reporting counts as
    /// answered once it is on, once the user declined, or once the prompt was dismissed.
    public static func isPromptDue(in defaults: UserDefaults = .standard) -> Bool {
        !isEnabled(in: defaults) && !wasAsked(in: defaults)
    }
}
