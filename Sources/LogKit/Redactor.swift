import Foundation

/// Removes credentials, request metadata, and filesystem paths from text before it
/// can be attached to a remote report or a prefilled GitHub issue.
///
/// The policy is intentionally conservative: if a value looks like a secret it is
/// replaced, even when that makes a diagnostic less detailed. Local `LogKit` files
/// keep the original text; redaction is only applied on the path to a remote service.
public enum Redactor {
    public static func redact(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var value = text
        value = replacingURLs(in: value)
        value = replace(Self.headerPattern, in: value, with: "$1: [REDACTED]")
        value = replace(Self.credentialPattern, in: value, with: "$1[REDACTED]")
        value = replace(Self.userInfoPattern, in: value, with: "$1[REDACTED]@")
        value = replace(Self.queryPattern, in: value, with: "$1=[REDACTED]")
        value = replace(Self.homePathPattern, in: value, with: "$1[redacted]")
        value = replace(Self.windowsHomePathPattern, in: value, with: "$1[redacted]")
        value = replace(Self.emailPattern, in: value, with: "[redacted-email]")
        return value
    }

    /// A second line of defence: an event whose redacted text still contains a
    /// recognizable secret is dropped rather than sent in the hope that it is safe.
    public static func containsSensitiveData(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return firstMatch(Self.residualHeaderPattern, in: text) != nil
            || firstMatch(Self.residualCredentialPattern, in: text) != nil
            || firstMatch(Self.residualQueryPattern, in: text) != nil
            || firstMatch(Self.residualUserInfoPattern, in: text) != nil
            || firstMatch(Self.residualHomePathPattern, in: text) != nil
            || firstMatch(Self.emailPattern, in: text) != nil
    }

    // MARK: - Patterns

    private static let headerPattern = pattern(
        #"(?i)\b(authorization|proxy-authorization|cookie|set-cookie)\b\s*[:=]\s*(?!\[REDACTED\])[^\r\n]+"#
    )
    private static let credentialPattern = pattern(
        #"(?i)(\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|api[_-]?key|apikey|x-api-key|client[_-]?secret|password|passwd|pwd|secret|session[_-]?(?:id|token)|proxy[_-]?(?:user(?:name)?|password|auth))\b["']?\s*[:=]\s*)(?!\[REDACTED\])(?:"[^"]*"|'[^']*'|[^\s&,;}\]]+)"#
    )
    private static let userInfoPattern = pattern(#"(?i)\b([a-z][a-z0-9+.-]*://)([^/\s@]+)@"#)
    private static let queryPattern = pattern(#"([?&][A-Za-z0-9_.~%-]+)=((?!\[REDACTED\])[^&#\s]*)"#)
    private static let homePathPattern = pattern(#"(?i)(/(?:Users|home)/)(?!\[redacted\])[^/\s]+"#)
    private static let windowsHomePathPattern = pattern(#"(?i)([A-Z]:\\Users\\)(?!\[redacted\])[^\\\s]+"#)
    private static let emailPattern = pattern(#"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}"#)

    private static let residualHeaderPattern = pattern(
        #"(?i)\b(?:authorization|proxy-authorization|cookie|set-cookie)\b\s*[:=]\s*(?!\[REDACTED\])\S"#
    )
    private static let residualCredentialPattern = pattern(
        #"(?i)\b(?:access[_-]?token|refresh[_-]?token|id[_-]?token|auth[_-]?token|api[_-]?key|apikey|x-api-key|client[_-]?secret|password|passwd|pwd|secret|session[_-]?(?:id|token)|proxy[_-]?(?:user(?:name)?|password|auth))\b["']?\s*[:=]\s*(?!\[REDACTED\])\S"#
    )
    private static let residualQueryPattern = pattern(#"[?&][A-Za-z0-9_.~%-]+=(?!\[REDACTED\])\S"#)
    private static let residualUserInfoPattern = pattern(#"(?i)\b[a-z][a-z0-9+.-]*://[^/\s@]+@"#)
    private static let residualHomePathPattern = pattern(#"(?i)/(?:Users|home)/(?!\[redacted\])[^/\s]+"#)

    private static let urlPattern = pattern(#"(?i)\b(?:https?|wss?)://[^\s<>"'(){}]+"#)

    // MARK: - Helpers

    private static func pattern(_ source: String) -> NSRegularExpression {
        // These patterns are constants and validated by the unit tests; a failure
        // here is a programmer error, so crash only during development.
        do {
            return try NSRegularExpression(pattern: source)
        } catch {
            assertionFailure("invalid redaction pattern: \(error)")
            return try! NSRegularExpression(pattern: #"(?!)"#)
        }
    }

    private static func replace(_ expression: NSRegularExpression, in text: String, with template: String) -> String {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.stringByReplacingMatches(in: text, options: [], range: range, withTemplate: template)
    }

    private static func firstMatch(_ expression: NSRegularExpression, in text: String) -> NSTextCheckingResult? {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return expression.firstMatch(in: text, options: [], range: range)
    }

    /// Keep the scheme and host, drop the path, query, fragment, and user info.
    /// A stripped URL still tells a developer which service failed without carrying
    /// the exact request that a proxy user was inspecting.
    private static func replacingURLs(in text: String) -> String {
        let matches = urlPattern.matches(in: text, options: [], range: NSRange(text.startIndex..<text.endIndex, in: text))
        guard !matches.isEmpty else { return text }

        var result = text
        for match in matches.reversed() {
            guard let range = Range(match.range, in: result) else { continue }
            let raw = String(result[range])
            result.replaceSubrange(range, with: safeURL(from: raw))
        }
        return result
    }

    private static func safeURL(from raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: CharacterSet(charactersIn: ".,;:!?"))
        let trailing = raw.dropFirst(trimmed.count)
        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme,
              let host = components.host
        else { return "[redacted-url]" + trailing }

        let port = components.port.map { ":\($0)" } ?? ""
        let path = components.path
        let suffix = (path.isEmpty || path == "/") ? "" : "/[redacted]"
        return "\(scheme)://\(host)\(port)\(suffix)" + trailing
    }
}
