import Foundation
import LogKit
import Sentry

/// The small seam between the reporting service and the Sentry SDK.
///
/// Tests replace this with a fake so they can assert initialization, consent, and
/// shutdown behaviour without starting the real SDK or reaching the network.
public protocol SentryBackend: AnyObject {
    func start(options: Options) -> Bool
    func close()
    func capture(error: Error, context: DiagnosticContext?)
}

/// The production backend. Every call is guarded by `SentryCrashReportingService`;
/// no other part of ProxyMaxx imports Sentry.
public final class SentrySDKBackend: SentryBackend {
    public init() {}

    public func start(options: Options) -> Bool {
        SentrySDK.start(options: options)
        return true
    }

    public func close() {
        SentrySDK.close()
    }

    public func capture(error: Error, context: DiagnosticContext?) {
        SentrySDK.capture(error: error) { scope in
            scope.clearBreadcrumbs()
            scope.clearAttachments()
            scope.setUser(nil)
            guard let context else { return }
            scope.setTag(value: context.component, key: "component")
            scope.setTag(value: context.correlationID, key: "correlation_id")
            if let operation = context.operation {
                scope.setTag(value: operation, key: "operation")
            }
            if let errorCode = context.errorCode {
                scope.setTag(value: errorCode, key: "error_code")
            }
            var diagnostic: [String: Any] = ["component": context.component]
            if let operation = context.operation { diagnostic["operation"] = operation }
            if let errorCode = context.errorCode { diagnostic["error_code"] = errorCode }
            if let message = context.message { diagnostic["message"] = message }
            scope.setContext(value: diagnostic, key: "diagnostic")
        }
    }
}
