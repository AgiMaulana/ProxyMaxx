import Foundation
import Branding

/// The starter response the app's **Insert Default Template** button writes, shared with
/// the CLI so a generated override is a complete HTTP/1.1 message the engine can parse.
///
/// A mapped file is either a full HTTP message (this template) or a raw body. Starting from
/// a full message is the safer default: status, content type and framing stay explicit, and
/// editing the JSON body cannot accidentally change how the response is served.
public enum MapLocalResponseTemplate {
    /// The exact bytes `rule template` and the editor button insert.
    public static let message = """
    HTTP/1.1 200 OK
    Content-Type: application/json; charset=utf-8

    {
      "message": "success",
      "data": {}
    }
    """

    /// UTF-8 bytes of ``message``.
    public static var data: Data { Data(message.utf8) }

    /// Where the app creates fresh response files: `Application Support/ProxyMaxx/map-local`.
    public static var directory: URL {
        Brand.supportDirectory.appendingPathComponent("map-local", isDirectory: true)
    }

    /// A unique response path in ``directory``, matching the app's `default_message_<8>.json`.
    public static func defaultFileURL(in directory: URL = directory) -> URL {
        directory.appendingPathComponent("default_message_\(UUID().uuidString.prefix(8)).json")
    }

    /// Write the template to `url` — a new unique file in ``directory`` when nil — creating
    /// parent directories as needed.
    ///
    /// Existing files are refused unless `overwrite` is true, so a mistyped path cannot
    /// replace a response the user already edited.
    @discardableResult
    public static func write(
        to url: URL? = nil,
        overwrite: Bool = false,
        fileManager: FileManager = .default
    ) throws -> URL {
        let destination = url ?? defaultFileURL()
        if !overwrite, fileManager.fileExists(atPath: destination.path) {
            throw MapLocalResponseTemplateError.fileExists(destination.path)
        }
        try fileManager.createDirectory(
            at: destination.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: destination, options: .atomic)
        return destination
    }
}

/// Failures ``MapLocalResponseTemplate/write(to:overwrite:fileManager:)`` reports to a caller
/// that has a place to show them; the CLI turns these into its usual one-line errors.
public enum MapLocalResponseTemplateError: LocalizedError, Equatable, Sendable {
    case fileExists(String)

    public var errorDescription: String? {
        switch self {
        case .fileExists(let path):
            return "a file already exists at \(path) — pass --force to overwrite it"
        }
    }
}
