import Foundation
import Logging

/// Plain-text structured log handler backed by the shared rotating file.
///
/// Every line carries the fields issue #35 asks for: timestamp, level,
/// component (derived from the logger label), the message, and any metadata —
/// operation, correlation ID, error code — rendered as `key=value` pairs.
/// Metadata values are quoted so multi-word diagnostics survive the flat
/// format.
///
///     2026-11-07 10:00:00.123 [info] [ProxyKit.Engine] proxy listening port=9090 correlation-id=abc123
public struct StructuredLogHandler: LogHandler {
    public var logLevel: Logger.Level = .info
    public var metadata = Logger.Metadata()

    private let label: String
    private let file: RotatingLogFile

    /// Shared writer so every handler instance appends to the same ring.
    static let sharedFile = RotatingLogFile()

    public init(label: String) {
        self.init(label: label, file: Self.sharedFile)
    }

    init(label: String, file: RotatingLogFile) {
        self.label = label
        self.file = file
    }

    public func log(event: LogEvent) {
        let fields = event.metadata ?? self.metadata
        file.append(Self.line(level: event.level, component: component, message: "\(event.message)", fields: fields))
    }

    public subscript(metadataKey metadataKey: String) -> Logger.Metadata.Value? {
        get { metadata[metadataKey] }
        set { metadata[metadataKey] = newValue }
    }

    private var component: String {
        // `oss.proxymaxx.proxykit.engine` → `Proxykit.Engine`
        let segments = label.split(separator: ".").dropFirst(2)
        let names = segments.map { $0.prefix(1).uppercased() + $0.dropFirst() }
        return names.isEmpty ? label : names.joined(separator: ".")
    }

    /// One flat log line: timestamp, level, component, message, then sorted
    /// `key=value` metadata.
    static func line(
        level: Logger.Level,
        component: String,
        message: String,
        fields: Logger.Metadata = [:]
    ) -> String {
        var text = timestamp() + " [\(level)] [\(component)] \(message)"
        for key in fields.keys.sorted() {
            text += " \(key)=\(quote(fields[key]!))"
        }
        return text
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        formatter.timeZone = .current
        return formatter.string(from: Date())
    }

    private static func quote(_ value: Logger.Metadata.Value) -> String {
        let raw = description(of: value)
        if raw.contains(" ") || raw.isEmpty {
            return "\"\(raw)\""
        }
        return raw
    }

    private static func description(of value: Logger.Metadata.Value) -> String {
        switch value {
        case .string(let string): return string
        case .stringConvertible(let convertible): return convertible.description
        default: return "\(value)"
        }
    }
}

/// Entry point for wiring the rotating files into swift-log.
public enum LogKit {
    private static let bootstrapOnce: Void = {
        LoggingSystem.bootstrap { StructuredLogHandler(label: $0) }
    }()

    /// Install the rotating-file handler as the global swift-log backend. Safe to
    /// call from every process entry point; only the first call has an effect.
    public static func bootstrap() {
        _ = bootstrapOnce
    }

    /// The shared rotating writer, for callers that log directly (App/CLI events
    /// that do not own a swift-log `Logger`).
    public static var logFile: RotatingLogFile {
        StructuredLogHandler.sharedFile
    }

    /// Write one line from a front-end that has no swift-log `Logger`: the app's
    /// activity feed and the CLI's stderr notes. Same shape as engine lines.
    public static func record(_ message: String, component: String, level: Logger.Level = .info) {
        logFile.append(StructuredLogHandler.line(level: level, component: component, message: message))
    }
}
