import Foundation

/// Reads a raw HTTP/1.x message out of a file.
///
/// Map Local accepts two shapes of mapped file: a full HTTP response message, or a
/// bare body. This is the first of those: the file starts with a `HTTP/...` status
/// line and the caller has already decided it is a message rather than a payload.
public enum HTTPMessageParser {
    /// Parse `data` as an HTTP/1.x response. Returns nil when it is not one.
    public static func response(from data: Data) -> HTTPResponse? {
        let (head, body) = splitHeadAndBody(data)
        guard let headText = String(data: head, encoding: .utf8) else { return nil }

        var lines = headText
            .components(separatedBy: "\n")
            .map { $0.hasSuffix("\r") ? String($0.dropLast()) : $0 }
        while lines.last?.isEmpty == true { lines.removeLast() }
        guard let statusLine = lines.first,
              let status = parseStatusLine(statusLine) else { return nil }

        var headers = HTTPHeaders()
        for line in lines.dropFirst() {
            guard !line.isEmpty else { continue }
            guard let colon = line.firstIndex(of: ":") else { return nil }
            let name = String(line[line.startIndex..<colon]).trimmingCharacters(in: .whitespaces)
            let value = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespaces)
            guard !name.isEmpty else { return nil }
            headers.add(name: name, value: value)
        }

        return HTTPResponse(
            statusCode: status.code,
            httpVersion: status.version,
            headers: headers,
            body: body
        )
    }

    /// `HTTP/1.1 200 OK` → version, code. The reason phrase is not kept: the proxy
    /// re-derives it from the status code with the same table the inspector uses.
    static func parseStatusLine(_ line: String) -> (version: String, code: Int)? {
        let parts = line.split(separator: " ", omittingEmptySubsequences: true).map(String.init)
        guard parts.count >= 2 else { return nil }
        guard parts[0].uppercased().hasPrefix("HTTP/") else { return nil }
        guard let code = Int(parts[1]), (100...599).contains(code) else { return nil }
        return (parts[0], code)
    }

    /// Split at the first blank line. A message with no body still counts.
    static func splitHeadAndBody(_ data: Data) -> (head: Data, body: Data) {
        let bytes = [UInt8](data)
        if let index = firstIndex(of: [13, 10, 13, 10], in: bytes) {
            return (Data(bytes[0..<index]), Data(bytes[(index + 4)...]))
        }
        if let index = firstIndex(of: [10, 10], in: bytes) {
            return (Data(bytes[0..<index]), Data(bytes[(index + 2)...]))
        }
        return (data, Data())
    }

    private static func firstIndex(of needle: [UInt8], in haystack: [UInt8]) -> Int? {
        guard !needle.isEmpty, haystack.count >= needle.count else { return nil }
        let limit = haystack.count - needle.count
        for start in 0...limit where haystack[start] == needle[0] {
            if haystack[start..<(start + needle.count)].elementsEqual(needle) { return start }
        }
        return nil
    }
}
