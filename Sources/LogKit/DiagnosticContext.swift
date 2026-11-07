import Foundation

/// The only application metadata a remote crash report may carry.
///
/// Values are deliberately small and symbolic: a component, an operation, an
/// error code, a random correlation ID, and an already-redacted message. Anything
/// that could identify a person, a request, or a captured flow belongs in the local
/// log, not here.
public struct DiagnosticContext: Sendable, Equatable {
    public let component: String
    public let operation: String?
    public let errorCode: String?
    public let correlationID: String
    public let message: String?

    public init(
        component: String,
        operation: String? = nil,
        errorCode: String? = nil,
        correlationID: String = UUID().uuidString,
        message: String? = nil
    ) {
        self.component = component
        self.operation = operation
        self.errorCode = errorCode
        self.correlationID = correlationID
        self.message = message
    }
}

/// An error assembled from a descriptive string, so a failure that arrives as text
/// can still travel through the same reporting path as a thrown `Error`.
public struct DiagnosticError: Error, LocalizedError, CustomStringConvertible {
    public let code: String
    public let message: String

    public init(code: String, message: String) {
        self.code = code
        self.message = message
    }

    public var errorDescription: String? { message }
    public var description: String { message }
}
