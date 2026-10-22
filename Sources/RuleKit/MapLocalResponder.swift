import Foundation
import FlowKit

/// A Map Local rule that matched, together with the response it produced.
public struct MapLocalResolution: Sendable {
    public let ruleName: String
    public let destination: MapLocalDestination
    /// The file actually served, after directory resolution and `FILE_URL` indirection.
    public let servedPath: String
    public let response: HTTPResponse
    /// Seconds the proxy waits before sending `response`.
    public let delay: TimeInterval

    /// One line for the inspector: what was mapped and from where.
    public var sourceDescription: String {
        "\(destination.displayName): \(servedPath)"
    }
}

/// What happened when a request was checked against the Map Local rules.
public enum MapLocalOutcome: Sendable {
    /// A rule matched and its content was read; the response can be served.
    case served(MapLocalResolution)
    /// A rule matched but its content is unusable. The request falls through to the
    /// remote server, so a mapped file or directory that has disappeared does not break
    /// the page.
    case unusable(ruleName: String, reason: String)
}

/// Turns a matched Map Local rule into a response by reading the mapped file or directory.
///
/// File access is synchronous. That is deliberate: the payload is a file the user chose
/// on their own machine, and the read happens once per matched request.
public enum MapLocalResponder {
    /// Check `rules` in order and produce a response for the first match.
    ///
    /// Returns nil when no rule matched, which means the request is forwarded upstream.
    public static func resolve(request: HTTPRequest, rules: [MapLocalRule]) -> MapLocalOutcome? {
        guard let rule = MapLocalMatcher.firstMatch(in: rules, request: request) else { return nil }
        switch rule.destination {
        case .file(let path):
            return resolveFile(rule: rule, path: path)
        case .directory(let path):
            return resolveDirectory(rule: rule, path: path, request: request)
        }
    }

    // MARK: - Local file

    private static func resolveFile(rule: MapLocalRule, path: String) -> MapLocalOutcome {
        guard let fileURL = readableFile(at: path, rule: rule) else {
            return .unusable(ruleName: rule.displayName, reason: "Body file is missing at \(expand(path).path)")
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unusable(ruleName: rule.displayName, reason: "Body file is missing at \(fileURL.path)")
        }
        return .served(
            MapLocalResolution(
                ruleName: rule.displayName,
                destination: rule.destination,
                servedPath: fileURL.path,
                response: makeResponse(from: data, pathExtension: fileURL.pathExtension),
                delay: rule.responseDelay
            )
        )
    }

    /// Resolve `FILE_URL` indirection, following it one step.
    ///
    /// ProxyMaxx lets a mapped file hold nothing but `<FILE_URL="~/Desktop/myfile.json">`
    /// so the file the editor points at can itself be a pointer.
    private static func readableFile(at path: String, rule: MapLocalRule) -> URL? {
        let url = expand(path)
        guard let data = try? Data(contentsOf: url) else { return nil }
        guard let reference = fileReference(in: data) else { return url }
        let referenced = expand(reference)
        return FileManager.default.fileExists(atPath: referenced.path) ? referenced : nil
    }

    static func fileReference(in data: Data) -> String? {
        let prefix = "<FILE_URL="
        guard let text = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
              text.hasPrefix(prefix), text.hasSuffix(">") else { return nil }
        let inner = text.dropFirst(prefix.count).dropLast()
            .trimmingCharacters(in: CharacterSet(charactersIn: "\u{22}\u{201C}\u{201D}"))
        return inner.isEmpty ? nil : inner
    }

    /// Build a response from file bytes: a full HTTP message if the file is one,
    /// otherwise the bytes themselves as the body.
    static func makeResponse(from data: Data, pathExtension: String) -> HTTPResponse {
        if looksLikeHTTPMessage(data), let message = HTTPMessageParser.response(from: data) {
            return normalized(message, pathExtension: pathExtension)
        }
        var headers = HTTPHeaders()
        headers["Content-Type"] = MIMEType.inferred(forPathExtension: pathExtension).essence
        headers["Content-Length"] = "\(data.count)"
        return HTTPResponse(statusCode: 200, headers: headers, body: data)
    }

    /// A message file must frame itself correctly, so length and transfer-encoding are
    /// taken from the body the file actually carries rather than trusted from its headers.
    static func normalized(_ message: HTTPResponse, pathExtension: String) -> HTTPResponse {
        var response = message
        response.headers.remove(name: "Transfer-Encoding")
        let forbidsBody = response.statusCode == 204
            || response.statusCode == 304
            || (100..<200).contains(response.statusCode)
        if forbidsBody {
            response.body = Data()
            response.headers.remove(name: "Content-Length")
        } else {
            response.headers["Content-Length"] = "\(response.body.count)"
            if response.headers["Content-Type"] == nil {
                response.headers["Content-Type"] = MIMEType.inferred(forPathExtension: pathExtension).essence
            }
        }
        return response
    }

    static func looksLikeHTTPMessage(_ data: Data) -> Bool {
        var bytes = [UInt8](data.prefix(64))
        while let first = bytes.first, first == 0x20 || first == 0x09 || first == 0x0A || first == 0x0D {
            bytes.removeFirst()
        }
        return String(decoding: bytes.prefix(5), as: UTF8.self).uppercased() == "HTTP/"
    }

    // MARK: - Local directory

    private static func resolveDirectory(rule: MapLocalRule, path: String, request: HTTPRequest) -> MapLocalOutcome {
        let root = expand(path)
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: root.path, isDirectory: &isDirectory), isDirectory.boolValue else {
            return .unusable(ruleName: rule.displayName, reason: "Directory is missing at \(root.path)")
        }
        guard let fileURL = directoryTarget(root: root, requestPath: request.pathWithoutQuery) else {
            return .unusable(
                ruleName: rule.displayName,
                reason: "No file under \(root.path) for \(request.pathWithoutQuery)"
            )
        }
        guard let data = try? Data(contentsOf: fileURL) else {
            return .unusable(ruleName: rule.displayName, reason: "Body file is missing at \(fileURL.path)")
        }
        return .served(
            MapLocalResolution(
                ruleName: rule.displayName,
                destination: rule.destination,
                servedPath: fileURL.path,
                response: makeResponse(from: data, pathExtension: fileURL.pathExtension),
                delay: rule.responseDelay
            )
        )
    }

    /// Map a request path onto a file under `root`.
    ///
    /// The request path is walked onto the root, so `/api/users.json` under
    /// `~/mock` answers from `~/mock/api/users.json`. A directory target falls back
    /// to its `index.html`. Anything that would climb out of the root, by `..` or by
    /// a symlink, is refused rather than served.
    static func directoryTarget(root: URL, requestPath: String) -> URL? {
        let decoded = requestPath.removingPercentEncoding ?? requestPath
        let components = decoded
            .split(separator: "/")
            .map(String.init)
            .filter { !$0.isEmpty && $0 != "." }
        guard !components.contains("..") else { return nil }

        let candidate = components.reduce(root) { $0.appendingPathComponent($1) }
        // Resolve symlinks before the containment check: `standardizedFileURL` only
        // collapses `..` textually, so a symlink that points outside the root would
        // otherwise pass and leak a file the user never mapped.
        let rootPath = root.resolvingSymlinksInPath().standardizedFileURL.path
        let candidatePath = candidate.resolvingSymlinksInPath().standardizedFileURL.path
        guard candidatePath == rootPath || candidatePath.hasPrefix(rootPath + "/") else { return nil }

        let fileManager = FileManager.default
        var isDirectory: ObjCBool = false
        guard fileManager.fileExists(atPath: candidatePath, isDirectory: &isDirectory) else { return nil }
        if !isDirectory.boolValue { return candidate }

        for index in ["index.html", "index.htm"] {
            let indexURL = candidate.appendingPathComponent(index)
            if fileManager.fileExists(atPath: indexURL.path) { return indexURL }
        }
        return nil
    }

    static func expand(_ path: String) -> URL {
        URL(fileURLWithPath: (path as NSString).expandingTildeInPath)
    }
}
