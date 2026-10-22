import Foundation

/// A parsed `Content-Type` value: `type/subtype; param=value`.
public struct MIMEType: Codable, Hashable, Sendable {
    public let type: String
    public let subtype: String
    public let parameters: [String: String]

    public init?(rawValue: String) {
        let parts = rawValue.split(separator: ";").map { $0.trimmingCharacters(in: .whitespaces) }
        guard let essence = parts.first, essence.contains("/") else { return nil }
        let components = essence.split(separator: "/", maxSplits: 1).map(String.init)
        guard components.count == 2 else { return nil }
        self.type = components[0].lowercased()
        self.subtype = components[1].lowercased()
        var params: [String: String] = [:]
        for part in parts.dropFirst() {
            guard let eq = part.firstIndex(of: "=") else { continue }
            let key = part[part.startIndex..<eq].trimmingCharacters(in: .whitespaces).lowercased()
            let value = part[part.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            params[key] = value.trimmingCharacters(in: CharacterSet(charactersIn: "\""))
        }
        self.parameters = params
    }

    public init(type: String, subtype: String, parameters: [String: String] = [:]) {
        self.type = type.lowercased()
        self.subtype = subtype.lowercased()
        self.parameters = parameters
    }

    public var essence: String { "\(type)/\(subtype)" }

    public var charset: String? { parameters["charset"] }

    public var isText: Bool {
        type == "text" || isJSON || subtype == "xml" || subtype == "javascript" || subtype == "x-www-form-urlencoded"
    }

    public var isJSON: Bool {
        subtype == "json" || subtype.hasSuffix("+json")
    }

    public var isXML: Bool {
        subtype == "xml" || subtype.hasSuffix("+xml") || subtype == "html" || subtype == "xhtml"
    }

    public var isHTML: Bool { subtype == "html" || subtype == "xhtml" }

    public var isImage: Bool { type == "image" }

    public var isForm: Bool { subtype == "x-www-form-urlencoded" }

    public var isMultipart: Bool { subtype.hasPrefix("multipart") }

    public var isJavaScript: Bool {
        subtype == "javascript" || subtype == "ecmascript" || subtype == "x-javascript"
    }

    public var isCSS: Bool { subtype == "css" }

    public var isBinary: Bool {
        !isText && !isImage && !isJSON && !isXML && !isForm && !isMultipart && !isJavaScript && !isCSS
    }

    public var isGraphQL: Bool {
        isJSON && parameters["x-graphql"] != nil
    }

    /// Guess a content type from a file extension.
    ///
    /// Map Local serves an arbitrary file as a response body, and the client needs a
    /// content type to render it, so the extension is the only signal available.
    /// An unknown extension resolves to `application/octet-stream`, which is what the
    /// bytes honestly are when nothing identifies them.
    public static func inferred(forPathExtension pathExtension: String) -> MIMEType {
        let ext = pathExtension.lowercased()
        let essence: String
        switch ext {
        case "html", "htm": essence = "text/html"
        case "css": essence = "text/css"
        case "js", "mjs", "cjs": essence = "text/javascript"
        case "json", "map": essence = "application/json"
        case "xml", "plist", "xhtml": essence = "application/xml"
        case "svg": essence = "image/svg+xml"
        case "txt", "text", "log", "md", "markdown", "csv", "tsv", "yaml", "yml", "ini", "conf": essence = "text/plain"
        case "png": essence = "image/png"
        case "jpg", "jpeg": essence = "image/jpeg"
        case "gif": essence = "image/gif"
        case "webp": essence = "image/webp"
        case "ico": essence = "image/x-icon"
        case "bmp": essence = "image/bmp"
        case "tiff", "tif": essence = "image/tiff"
        case "pdf": essence = "application/pdf"
        case "zip": essence = "application/zip"
        case "gz": essence = "application/gzip"
        case "wasm": essence = "application/wasm"
        case "mp3": essence = "audio/mpeg"
        case "wav": essence = "audio/wav"
        case "mp4": essence = "video/mp4"
        case "woff": essence = "font/woff"
        case "woff2": essence = "font/woff2"
        case "ttf": essence = "font/ttf"
        case "otf": essence = "font/otf"
        default: essence = "application/octet-stream"
        }
        let parts = essence.split(separator: "/", maxSplits: 1).map(String.init)
        return MIMEType(type: parts.first ?? "application", subtype: parts.count > 1 ? parts[1] : "octet-stream")
    }
}
