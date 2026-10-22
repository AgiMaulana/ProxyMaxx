import Foundation

/// Presentation helpers for request/response bodies.
public enum BodyFormatting {
    /// Decode body bytes to text using the declared charset, falling back to UTF-8.
    public static func text(from data: Data, contentType: MIMEType? = nil) -> String? {
        guard !data.isEmpty else { return "" }
        if let charset = contentType?.charset {
            let cfEncoding = CFStringConvertIANACharSetNameToEncoding(charset as CFString)
            if cfEncoding != kCFStringEncodingInvalidId {
                let nsEncoding = CFStringConvertEncodingToNSStringEncoding(cfEncoding)
                if let string = NSString(data: data, encoding: nsEncoding) {
                    return string as String
                }
            }
        }
        if let string = String(data: data, encoding: .utf8) {
            return string
        }
        // Latin-1 is a lossless fallback for arbitrary bytes.
        return String(data: data, encoding: .isoLatin1)
    }

    /// Pretty-printed JSON when the body is valid JSON, otherwise nil.
    public static func prettyJSON(_ data: Data) -> String? {
        guard !data.isEmpty else { return nil }
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        guard let pretty = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes, .fragmentsAllowed]
        ) else {
            return nil
        }
        return String(data: pretty, encoding: .utf8)
    }

    public static func isValidJSON(_ data: Data) -> Bool {
        guard !data.isEmpty else { return false }
        return (try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) != nil
    }

    /// Parse an `application/x-www-form-urlencoded` body into ordered pairs.
    public static func formPairs(_ data: Data) -> [(name: String, value: String)] {
        guard let raw = String(data: data, encoding: .utf8), !raw.isEmpty else { return [] }
        return raw.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let name = kv.first?.removingPercentEncoding ?? kv.first ?? ""
            let value = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
            return (name, value)
        }
    }

    /// Classic hex + ASCII dump.
    ///
    /// Built by concatenation rather than a printf format: `String(format:)` with a
    /// mix of integer and object arguments is not type-checked, and a malformed body
    /// took the whole app down through it.
    public static func hexDump(_ data: Data, bytesPerLine: Int = 16) -> String {
        guard !data.isEmpty, bytesPerLine > 0 else { return "" }
        var lines: [String] = []
        lines.reserveCapacity(data.count / bytesPerLine + 1)
        let bytes = [UInt8](data)
        let hexWidth = bytesPerLine * 3 - 1
        var offset = 0
        while offset < bytes.count {
            let slice = bytes[offset..<min(offset + bytesPerLine, bytes.count)]
            let hex = slice.map(hexPair).joined(separator: " ")
            let ascii = String(slice.map { byte -> Character in
                (byte >= 0x20 && byte < 0x7f) ? Character(UnicodeScalar(byte)) : "."
            })
            let paddedHex = hex + String(repeating: " ", count: max(0, hexWidth - hex.count))
            lines.append("\(hexOffset(offset))  \(paddedHex)  \(ascii)")
            offset += bytesPerLine
        }
        return lines.joined(separator: "\n")
    }

    private static let hexDigits = Array("0123456789abcdef")

    private static func hexPair(_ byte: UInt8) -> String {
        "\(hexDigits[Int(byte >> 4)])\(hexDigits[Int(byte & 0x0f)])"
    }

    private static func hexOffset(_ value: Int) -> String {
        let digits = String(value, radix: 16)
        return String(repeating: "0", count: max(0, 8 - digits.count)) + digits
    }

    /// Human-readable byte count, e.g. `1.2 KB`.
    public static func byteCount(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .binary
        return formatter.string(fromByteCount: Int64(count))
    }
}
