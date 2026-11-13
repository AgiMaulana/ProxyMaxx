import Foundation
import FlowKit

/// A parsed HTTP Archive (`.har`) document, trimmed to the fields a Map Local
/// override needs.
///
/// Every field is optional so real-world HARs — which disagree about which
/// members they include — still decode; the importer treats a missing field as
/// "no data" rather than a parse failure.
public struct HARDocument: Codable, Sendable {
    public var log: HARLog?

    public init(log: HARLog?) { self.log = log }
}

public struct HARLog: Codable, Sendable {
    public var entries: [HAREntry]?

    public init(entries: [HAREntry]?) { self.entries = entries }
}

public struct HAREntry: Codable, Sendable {
    public var request: HARRequest?
    public var response: HARResponse?

    public init(request: HARRequest?, response: HARResponse?) {
        self.request = request
        self.response = response
    }
}

public struct HARRequest: Codable, Sendable {
    public var method: String?
    public var url: String?
    public var headers: [HARNameValue]?

    public init(method: String?, url: String?, headers: [HARNameValue]?) {
        self.method = method
        self.url = url
        self.headers = headers
    }
}

public struct HARResponse: Codable, Sendable {
    public var status: Int?
    public var statusText: String?
    public var headers: [HARNameValue]?
    public var content: HARContent?

    public init(status: Int?, statusText: String?, headers: [HARNameValue]?, content: HARContent?) {
        self.status = status
        self.statusText = statusText
        self.headers = headers
        self.content = content
    }
}

public struct HARNameValue: Codable, Sendable {
    public var name: String?
    public var value: String?

    public init(name: String?, value: String?) {
        self.name = name
        self.value = value
    }
}

public struct HARContent: Codable, Sendable {
    public var size: Int?
    public var mimeType: String?
    /// The decoded body text, or base64 when ``encoding`` is `"base64"`.
    public var text: String?
    public var encoding: String?

    public init(size: Int?, mimeType: String?, text: String?, encoding: String?) {
        self.size = size
        self.mimeType = mimeType
        self.text = text
        self.encoding = encoding
    }
}

/// Turns HAR entries into Map Local rules, one rule and one response file per
/// recorded response body.
///
/// The response file is a complete HTTP/1.1 message — the same shape
/// ``MapLocalResponseTemplate`` and the app's "map flow to Local Override"
/// produce — so status, headers and body stay explicit and the engine serves it
/// without extra inference. Bodies arrive decoded (`Content-Encoding` is
/// dropped from the written headers), which also keeps the files editable.
public enum HARImporter {
    /// Parse HAR bytes into entries. Throws when the document is not JSON at all.
    public static func parse(_ data: Data) throws -> [HAREntry] {
        let document = try JSONDecoder().decode(HARDocument.self, from: data)
        return document.log?.entries ?? []
    }

    /// The rule for `entry`, or nil when the entry has no usable URL or body.
    ///
    /// The pattern follows the app's "map flow to Local Override": scheme
    /// stripped, wildcard matching with the path included, and the recorded
    /// method pinned so a `GET` rule never swallows a `POST` to the same URL.
    public static func makeRule(for entry: HAREntry, responseFileURL: URL) -> MapLocalRule? {
        guard let request = entry.request, let rawURL = request.url,
              let body = bodyData(for: entry.response?.content), !body.isEmpty
        else { return nil }

        let cleanedURL = rawURL
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        guard !cleanedURL.isEmpty else { return nil }

        let parsedURL = URL(string: rawURL)
        let path = parsedURL?.path ?? ""
        let host = parsedURL?.host ?? ""
        let name = path.isEmpty || path == "/" ? host : path

        return MapLocalRule(
            name: name.isEmpty ? cleanedURL : name,
            method: MethodMatch(request.method ?? ""),
            url: cleanedURL,
            matchStyle: .wildcard,
            includePath: true,
            destination: .file(responseFileURL.path)
        )
    }

    /// Whether `entry` carries a response body an override can serve.
    public static func hasBody(_ entry: HAREntry) -> Bool {
        guard let body = bodyData(for: entry.response?.content) else { return false }
        return !body.isEmpty
    }

    /// The response body as raw bytes: base64-decoded when the HAR says so,
    /// otherwise the text encoded as UTF-8.
    public static func bodyData(for content: HARContent?) -> Data? {
        guard let content, let text = content.text else { return nil }
        if content.encoding?.caseInsensitiveCompare("base64") == .orderedSame {
            return Data(base64Encoded: text)
        }
        return Data(text.utf8)
    }

    /// Write `entry`'s response as a full HTTP/1.1 message to `url`, creating
    /// parent directories as needed. Existing files are refused so an import
    /// cannot silently replace a response the user already edited.
    @discardableResult
    public static func writeResponse(for entry: HAREntry, to url: URL, fileManager: FileManager = .default) throws -> URL {
        guard let response = entry.response else {
            throw HARImportError.missingResponse(url.path)
        }
        guard let body = bodyData(for: response.content) else {
            throw HARImportError.missingBody(url.path)
        }
        guard !fileManager.fileExists(atPath: url.path) else {
            throw HARImportError.fileExists(url.path)
        }

        let status = response.status ?? 200
        var message = "HTTP/1.1 \(status) \(statusReason(status, statusText: response.statusText))\r\n"
        for header in response.headers ?? [] {
            guard let name = header.name else { continue }
            // The body is written decoded, so framing headers describing the
            // original bytes would be wrong; the engine recomputes length when
            // it serves a message file.
            if name.caseInsensitiveCompare("Content-Encoding") == .orderedSame
                || name.caseInsensitiveCompare("Transfer-Encoding") == .orderedSame
                || name.caseInsensitiveCompare("Content-Length") == .orderedSame { continue }
            message += "\(name): \(header.value ?? "")\r\n"
        }
        message += "\r\n"

        var data = Data(message.utf8)
        // JSON is pretty-printed so the file stays editable, matching what the
        // app writes when mapping a captured flow.
        if let prettyJSON = BodyFormatting.prettyJSON(body) {
            data.append(Data(prettyJSON.utf8))
        } else {
            data.append(body)
        }

        try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url, options: .atomic)
        return url
    }

    /// A unique response path under `directory`, named after the entry's URL.
    public static func responseFileURL(for entry: HAREntry, in directory: URL) -> URL {
        let rawURL = entry.request?.url ?? ""
        let parsedURL = URL(string: rawURL)
        let base = parsedURL?.path.split(separator: "/").last.map(String.init) ?? "response"
        let sanitized = base
            .replacingOccurrences(of: "/", with: "-")
            .filter { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" || $0 == "_" }
        let prefix = sanitized.isEmpty ? "response" : String(sanitized.prefix(64))
        let ext = fileExtension(forMimeType: entry.response?.content?.mimeType)
        return directory.appendingPathComponent("har_\(UUID().uuidString.prefix(8))_\(prefix).\(ext)")
    }

    private static func statusReason(_ status: Int, statusText: String?) -> String {
        if let statusText, !statusText.isEmpty { return statusText }
        switch status {
        case 200: return "OK"
        case 201: return "Created"
        case 204: return "No Content"
        case 301: return "Moved Permanently"
        case 302: return "Found"
        case 304: return "Not Modified"
        case 400: return "Bad Request"
        case 401: return "Unauthorized"
        case 403: return "Forbidden"
        case 404: return "Not Found"
        case 500: return "Internal Server Error"
        case 502: return "Bad Gateway"
        case 503: return "Service Unavailable"
        default: return ""
        }
    }

    /// A file extension for `mimeType`, falling back to `bin` for anything unknown.
    public static func fileExtension(forMimeType mimeType: String?) -> String {
        let type = (mimeType ?? "").lowercased()
        let mapping = [
            "application/json": "json",
            "text/html": "html",
            "text/plain": "txt",
            "text/css": "css",
            "text/xml": "xml",
            "application/xml": "xml",
            "application/javascript": "js",
            "text/javascript": "js",
            "image/png": "png",
            "image/jpeg": "jpg",
            "image/gif": "gif",
            "image/svg+xml": "svg",
            "image/webp": "webp",
            "image/x-icon": "ico",
            "application/pdf": "pdf",
            "application/octet-stream": "bin",
        ]
        if let exact = mapping[type] { return exact }
        // A parameterized type such as `application/json; charset=utf-8`.
        let essence = type.split(separator: ";").first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
        return mapping[essence] ?? "bin"
    }
}

/// Failures ``HARImporter/writeResponse(for:to:fileManager:)`` reports.
public enum HARImportError: LocalizedError, Sendable {
    case missingResponse(String)
    case missingBody(String)
    case fileExists(String)

    public var errorDescription: String? {
        switch self {
        case .missingResponse(let path):
            return "the HAR entry has no response to write to \(path)"
        case .missingBody(let path):
            return "the HAR entry has no response body to write to \(path)"
        case .fileExists(let path):
            return "a file already exists at \(path)"
        }
    }
}
