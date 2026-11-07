import Foundation
import Branding

/// Thread-safe plain-text log file with size-based rotation.
///
/// Writes always go to `0.log`. When a write would push it past `maxFileBytes`,
/// the chain shifts: `9.log` becomes `10.log` (deleting whatever `10.log` held),
/// `8.log` becomes `9.log`, … `0.log` becomes `1.log`, and a fresh `0.log` is
/// created for the new line. `maxFiles` files are kept at most, so the whole
/// ring bounds disk use to `maxFiles × maxFileBytes`.
///
/// Layout: `…/ProxyMaxx/Logs/0.log` … `10.log`, a sibling of the registry and
/// the session log.
public final class RotatingLogFile {
    /// Where the rotating logs land by default.
    public static var defaultURL: URL {
        Brand.supportDirectory.appendingPathComponent("Logs", isDirectory: true).appendingPathComponent("0.log")
    }

    public let url: URL
    /// Soft cap per file. Rotation happens when a write would exceed it.
    public var maxFileBytes: Int
    /// Highest file number kept, counting `0.log`. The default keeps `0.log` through
    /// `10.log`, matching the issue's rule that a rotation with a `10.log` present
    /// deletes it and moves `9.log` up in its place.
    public var maxFiles: Int

    private let lock = NSLock()
    private let fileManager = FileManager.default

    public init(url: URL = RotatingLogFile.defaultURL, maxFileBytes: Int = 1 * 1024 * 1024, maxFiles: Int = 11) {
        self.url = url
        self.maxFileBytes = maxFileBytes
        self.maxFiles = maxFiles
    }

    /// Append one line (a trailing newline is added if missing). Rotation runs
    /// first so the newest line always lands in a `0.log` under the cap.
    public func append(_ line: String) {
        var text = line
        if !text.hasSuffix("\n") { text += "\n" }
        let data = Data(text.utf8)
        lock.lock(); defer { lock.unlock() }
        try? fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        if !fileManager.fileExists(atPath: url.path) {
            fileManager.createFile(atPath: url.path, contents: nil)
        }
        if currentBytes + data.count > maxFileBytes {
            rotateLocked()
        }
        guard let handle = try? FileHandle(forWritingTo: url) else { return }
        defer { try? handle.close() }
        _ = try? handle.seekToEnd()
        try? handle.write(contentsOf: data)
    }

    /// The newest `limit` lines of `0.log`, in write order, for issue reporting.
    public func latestLines(_ limit: Int) -> [String] {
        guard let text = latestText(maxBytes: maxFileBytes) else { return [] }
        return Array(text.split(separator: "\n", omittingEmptySubsequences: true).suffix(limit)).map(String.init)
    }

    /// The tail of `0.log`, at most `maxBytes` bytes, always starting on a line
    /// boundary so partial leading lines are dropped.
    public func latestText(maxBytes: Int) -> String? {
        lock.lock(); defer { lock.unlock() }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        let size = (try? handle.seekToEnd()) ?? 0
        guard size > 0 else { return nil }
        let start = size > UInt64(maxBytes) ? size - UInt64(maxBytes) : 0
        _ = try? handle.seek(toOffset: start)
        guard let data = try? handle.read(upToCount: Int(size - start)), !data.isEmpty else { return nil }
        var text = String(decoding: data, as: UTF8.self)
        if start > 0, let firstNewline = text.firstIndex(of: "\n") {
            text.removeSubrange(...firstNewline)
        }
        return text
    }

    /// The whole ring, oldest file first, for the CLI's `report` output.
    public func allText() -> String {
        lock.lock(); defer { lock.unlock() }
        var parts: [String] = []
        for index in stride(from: maxFiles - 1, through: 0, by: -1) {
            let fileURL = fileURL(for: index)
            guard let data = try? Data(contentsOf: fileURL), !data.isEmpty else { continue }
            parts.append(String(decoding: data, as: UTF8.self))
        }
        return parts.joined()
    }

    private var currentBytes: Int {
        let attributes = try? fileManager.attributesOfItem(atPath: url.path)
        return (attributes?[.size] as? NSNumber)?.intValue ?? 0
    }

    /// Shift every file up by one, dropping the oldest, and create a blank `0.log`.
    private func rotateLocked() {
        let oldest = fileURL(for: maxFiles - 1)
        if fileManager.fileExists(atPath: oldest.path) {
            try? fileManager.removeItem(at: oldest)
        }
        for index in stride(from: maxFiles - 2, through: 0, by: -1) {
            let source = fileURL(for: index)
            guard fileManager.fileExists(atPath: source.path) else { continue }
            try? fileManager.moveItem(at: source, to: fileURL(for: index + 1))
        }
        fileManager.createFile(atPath: url.path, contents: Data())
    }

    private func fileURL(for index: Int) -> URL {
        url.deletingLastPathComponent().appendingPathComponent("\(index).log")
    }
}
