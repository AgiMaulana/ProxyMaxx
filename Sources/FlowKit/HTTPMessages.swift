import Foundation

/// A captured HTTP request.
public struct HTTPRequest: Codable, Hashable, Sendable {
    public var method: String
    public var scheme: String
    public var host: String
    public var port: Int
    /// Path plus query string, always beginning with `/`.
    public var path: String
    public var httpVersion: String
    public var headers: HTTPHeaders
    public var body: Data

    public init(
        method: String,
        scheme: String,
        host: String,
        port: Int,
        path: String,
        httpVersion: String = "HTTP/1.1",
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data()
    ) {
        self.method = method
        self.scheme = scheme
        self.host = host
        self.port = port
        self.path = path.hasPrefix("/") ? path : "/" + path
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }

    public var isHTTPS: Bool { scheme.caseInsensitiveCompare("https") == .orderedSame }

    public var defaultPort: Int { isHTTPS ? 443 : 80 }

    public var urlString: String {
        let portPart = port == defaultPort ? "" : ":\(port)"
        return "\(scheme)://\(host)\(portPart)\(path)"
    }

    public var url: URL? { URL(string: urlString) }

    public var pathWithoutQuery: String {
        path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? path
    }

    public var query: String? {
        let parts = path.split(separator: "?", maxSplits: 1)
        return parts.count == 2 ? String(parts[1]) : nil
    }

    public var queryItems: [(name: String, value: String)] {
        guard let query else { return [] }
        return query.split(separator: "&").map { pair in
            let kv = pair.split(separator: "=", maxSplits: 1).map(String.init)
            let name = kv.first?.removingPercentEncoding ?? kv.first ?? ""
            let value = kv.count > 1 ? (kv[1].removingPercentEncoding ?? kv[1]) : ""
            return (name, value)
        }
    }

    public var contentType: MIMEType? { headers.contentType }

    public var contentEncoding: String? { headers["Content-Encoding"] }

    /// The body with its `Content-Encoding` reversed, or the raw bytes when the
    /// payload is uncompressed or the encoding is one this build cannot inflate.
    public var decodedBody: Data { ContentDecoding.decode(body, encoding: contentEncoding) ?? body }
}

/// A captured HTTP response.
public struct HTTPResponse: Codable, Hashable, Sendable {
    public var statusCode: Int
    public var httpVersion: String
    public var headers: HTTPHeaders
    public var body: Data

    public init(
        statusCode: Int,
        httpVersion: String = "HTTP/1.1",
        headers: HTTPHeaders = HTTPHeaders(),
        body: Data = Data()
    ) {
        self.statusCode = statusCode
        self.httpVersion = httpVersion
        self.headers = headers
        self.body = body
    }

    public var statusText: String { HTTPStatusText.text(for: statusCode) }

    public var contentType: MIMEType? { headers.contentType }

    public var contentEncoding: String? { headers["Content-Encoding"] }

    /// The body with its `Content-Encoding` reversed, or the raw bytes when the
    /// payload is uncompressed or the encoding is one this build cannot inflate.
    public var decodedBody: Data { ContentDecoding.decode(body, encoding: contentEncoding) ?? body }

    public var isSuccess: Bool { (200..<300).contains(statusCode) }
}

/// Minimal RFC 9110 reason-phrase table.
public enum HTTPStatusText {
    private static let table: [Int: String] = [
        100: "Continue", 101: "Switching Protocols", 102: "Processing", 103: "Early Hints",
        200: "OK", 201: "Created", 202: "Accepted", 203: "Non-Authoritative Information",
        204: "No Content", 205: "Reset Content", 206: "Partial Content", 207: "Multi-Status",
        208: "Already Reported", 226: "IM Used",
        300: "Multiple Choices", 301: "Moved Permanently", 302: "Found", 303: "See Other",
        304: "Not Modified", 305: "Use Proxy", 307: "Temporary Redirect", 308: "Permanent Redirect",
        400: "Bad Request", 401: "Unauthorized", 402: "Payment Required", 403: "Forbidden",
        404: "Not Found", 405: "Method Not Allowed", 406: "Not Acceptable",
        407: "Proxy Authentication Required", 408: "Request Timeout", 409: "Conflict",
        410: "Gone", 411: "Length Required", 412: "Precondition Failed", 413: "Content Too Large",
        414: "URI Too Long", 415: "Unsupported Media Type", 416: "Range Not Satisfiable",
        417: "Expectation Failed", 418: "I'm a teapot", 421: "Misdirected Request",
        422: "Unprocessable Content", 423: "Locked", 424: "Failed Dependency", 425: "Too Early",
        426: "Upgrade Required", 428: "Precondition Required", 429: "Too Many Requests",
        431: "Request Header Fields Too Large", 451: "Unavailable For Legal Reasons",
        500: "Internal Server Error", 501: "Not Implemented", 502: "Bad Gateway",
        503: "Service Unavailable", 504: "Gateway Timeout", 505: "HTTP Version Not Supported",
        506: "Variant Also Negotiates", 507: "Insufficient Storage", 508: "Loop Detected",
        510: "Not Extended", 511: "Network Authentication Required",
    ]

    public static func text(for code: Int) -> String {
        table[code] ?? ""
    }
}
