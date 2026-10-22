import Foundation
import FlowKit

/// Renders a captured request as a `curl` command that replays it.
public enum CurlCommand {
    /// Headers curl derives from the URL and body itself. Passing them through would
    /// either be ignored (`Host`), overwritten (`Content-Length`), or describe a
    /// connection curl is not making (`Connection`).
    private static let omittedHeaders: Set<String> = [
        "host", "content-length", "connection", "proxy-connection", "transfer-encoding",
    ]

    public static func make(for flow: Flow) -> String { make(from: flow.request) }

    public static func make(from request: HTTPRequest) -> String {
        var head = ["curl"]
        // `--data-raw` makes curl switch to POST, so a GET that carries a body has to
        // name its method or the replay silently becomes a different request.
        if request.method.caseInsensitiveCompare("GET") != .orderedSame || !request.body.isEmpty {
            head.append("--request \(request.method)")
        }
        head.append(shellQuote(request.urlString))

        var tail: [String] = []
        for header in request.headers.entries where !omittedHeaders.contains(header.name.lowercased()) {
            tail.append("--header \(shellQuote("\(header.name): \(header.value)"))")
        }

        if let body = bodyArgument(request.body) {
            tail.append(body)
        }
        return ([head.joined(separator: " ")] + tail).joined(separator: " \\\n  ")
    }

    private static func bodyArgument(_ body: Data) -> String? {
        guard !body.isEmpty else { return nil }
        // Text stays readable in the pasted command; bodies that are not UTF-8, or that
        // carry control bytes a shell cannot reproduce, only survive as escapes.
        if let text = textBody(body) {
            return "--data-raw \(shellQuote(text))"
        }
        return "--data-binary \(ansiCQuoted(body))"
    }

    private static func textBody(_ body: Data) -> String? {
        guard let text = String(data: body, encoding: .utf8) else { return nil }
        let hasUnprintableControl = text.unicodeScalars.contains { scalar in
            (scalar.value < 0x20 && scalar != "\t" && scalar != "\n" && scalar != "\r")
                || scalar.value == 0x7F
        }
        return hasUnprintableControl ? nil : text
    }

    /// Single quotes for a POSIX shell, with an embedded quote closing and reopening
    /// the string (`'\''`).
    private static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// `$'…'` quoting keeps arbitrary bytes in one argument without the command
    /// depending on the locale's encoding.
    private static func ansiCQuoted(_ body: Data) -> String {
        var quoted = "$'"
        for byte in body {
            switch byte {
            case 0x5C: quoted += "\\\\"
            case 0x27: quoted += "\\'"
            case 0x20...0x7E: quoted.append(Character(UnicodeScalar(byte)))
            default: quoted += String(format: "\\x%02x", byte)
            }
        }
        return quoted + "'"
    }
}

public extension Flow {
    /// A `curl` command that replays this request against the original host.
    var curlCommand: String { CurlCommand.make(for: self) }
}
