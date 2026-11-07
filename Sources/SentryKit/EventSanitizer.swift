import Foundation
import LogKit
import Sentry

/// The single gate every Sentry event passes through.
///
/// It does two things in one place: removes anything the SDK may have collected that
/// ProxyMaxx does not want to disclose, and sanitizes the text that is allowed to stay.
/// The cleaner rebuilds an event from an allowlist instead of trusting SDK defaults, so
/// a new automatic instrumentation cannot quietly add request data later.
public struct EventSanitizer: Sendable {
    public init() {}

    public func sanitize(_ event: Event) -> Event? {
        var mustDrop = false

        func scrub(_ value: String?) -> String? {
            guard let value else { return nil }
            let redacted = Redactor.redact(value)
            if Redactor.containsSensitiveData(redacted) {
                mustDrop = true
            }
            return redacted
        }

        func scrubRequired(_ value: String) -> String {
            scrub(value) ?? ""
        }

        // Prohibited wholesale. Nothing below re-adds them.
        event.user = nil
        event.request = nil
        event.extra = nil
        event.serverName = nil
        event.modules = nil
        event.fingerprint = nil
        event.error = nil
        event.breadcrumbs = []

        event.releaseName = scrub(event.releaseName)
        event.dist = scrub(event.dist)
        event.environment = scrub(event.environment)
        event.transaction = scrub(event.transaction)
        event.logger = scrub(event.logger)

        if let message = event.message {
            let safe = scrubRequired(message.formatted)
            event.message = safe.isEmpty ? nil : SentryMessage(formatted: safe)
        }

        event.tags = sanitizedTags(event.tags, scrub: scrub)
        event.context = sanitizedContext(event.context, scrub: scrub)

        if let exceptions = event.exceptions {
            for exception in exceptions {
                exception.value = scrub(exception.value)
                exception.type = scrub(exception.type)
                exception.module = baseName(exception.module, scrub: scrub)
                if let mechanism = exception.mechanism {
                    mechanism.desc = scrub(mechanism.desc)
                    mechanism.helpLink = nil
                    mechanism.data = nil
                    mechanism.meta = nil
                }
                if let stacktrace = exception.stacktrace {
                    sanitize(stacktrace, scrub: scrub)
                }
            }
        }

        if let stacktrace = event.stacktrace {
            sanitize(stacktrace, scrub: scrub)
        }

        if let threads = event.threads {
            for thread in threads {
                thread.name = scrub(thread.name)
                if let stacktrace = thread.stacktrace {
                    sanitize(stacktrace, scrub: scrub)
                }
            }
        }

        if let debugMeta = event.debugMeta {
            for image in debugMeta {
                image.codeFile = baseName(image.codeFile, scrub: scrub)
            }
        }

        return mustDrop ? nil : event
    }

    // MARK: - Context and tags

    private func sanitizedTags(
        _ tags: [String: String]?,
        scrub: (String?) -> String?
    ) -> [String: String] {
        let allowed: Set<String> = [
            "component", "subsystem", "operation", "error_code", "correlation_id",
            "handled", "level", "mechanism", "environment", "release", "dist",
            "transaction", "os", "runtime", "device",
        ]
        var result: [String: String] = [:]
        for (key, value) in tags ?? [:] where allowed.contains(key.lowercased()) {
            if let safe = scrub(value), !safe.isEmpty {
                result[key] = safe
            }
        }
        return result
    }

    private func sanitizedContext(
        _ context: [String: [String: Any]]?,
        scrub: (String?) -> String?
    ) -> [String: [String: Any]] {
        let allowed: [String: Set<String>] = [
            "app": [
                "app_start_time", "app_start_timestamp", "build_type", "identifier",
                "in_foreground", "name", "start_time", "version", "type",
                "free_memory", "memory_usage", "timezone",
            ],
            "os": ["name", "version", "build", "kernel_version", "rooted", "raw_description", "theme"],
            "device": [
                "arch", "family", "model", "model_id", "orientation", "screen_density",
                "screen_height_pixels", "screen_width_pixels", "processor_count",
                "memory_size", "locale", "timezone", "manufacturer", "brand",
                "is_emulator", "online", "charging", "battery_level", "low_power_mode",
                "simulator", "boot_time", "free_memory", "device_type",
            ],
            "runtime": ["name", "version", "build", "raw_description"],
            "diagnostic": ["component", "operation", "error_code", "correlation_id", "message"],
        ]

        var result: [String: [String: Any]] = [:]
        for (key, values) in context ?? [:] {
            let name = key.lowercased()
            guard let keys = allowed[name] else { continue }
            var safeValues: [String: Any] = [:]
            for (field, value) in values where keys.contains(field.lowercased()) {
                if let string = value as? String {
                    if let safe = scrub(string) { safeValues[field] = safe }
                } else if let bool = value as? Bool {
                    safeValues[field] = bool
                } else if let number = value as? NSNumber {
                    safeValues[field] = number
                }
                // Nested dictionaries and arbitrary objects are deliberately dropped.
            }
            if !safeValues.isEmpty {
                result[name] = safeValues
            }
        }
        return result
    }

    // MARK: - Stack traces

    private func sanitize(_ stacktrace: SentryStacktrace, scrub: (String?) -> String?) {
        stacktrace.registers = [:]
        stacktrace.snapshot = nil
        for frame in stacktrace.frames {
            frame.fileName = baseName(frame.fileName, scrub: scrub)
            frame.package = baseName(frame.package, scrub: scrub)
            frame.module = baseName(frame.module, scrub: scrub)
            frame.function = scrub(frame.function)
            // Source context can quote the exact request body or credential that made
            // the line fail. The frame still identifies where the failure happened.
            frame.contextLine = nil
            frame.preContext = nil
            frame.postContext = nil
            frame.vars = nil
        }
    }

    private func baseName(_ value: String?, scrub: (String?) -> String?) -> String? {
        guard let value, !value.isEmpty else { return nil }
        let name = (value as NSString).lastPathComponent
        return scrub(name)
    }
}
