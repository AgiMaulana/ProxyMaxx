import Foundation
import FlowKit

/// Shared, file-backed stream of captured flows between the two front-ends of the
/// same tool: the GUI window and the `proxymaxx-cli` binary.
///
/// Only one process runs the proxy engine at a time (see `ProxyRegistry`), but both
/// front-ends are peers over the same session: the app and the CLI are one program
/// with two ways to drive it. Whichever process hosts the engine writes every flow
/// snapshot here; the other reads them, so attaching shows live traffic instead of
/// just a status line. Ownership is about *who runs the engine*, not about which
/// front-end is allowed to see the session.
///
/// Layout: `…/ProxyMaxx/ipc/flows/<sequence>-<flow-uuid>.json`
///
/// Each snapshot is written under a fresh, sequence-prefixed name and never
/// rewritten, which is what lets the reader delete what it has consumed without
/// racing the writer: a reader only ever removes a file that is already immutable.
/// Ordering falls out of the zero-padded sequence prefix, so a plain lexicographic
/// sort replays snapshots in the order they were captured. The writer drops a flow's
/// previous file when it writes the next snapshot, so the directory holds at most one
/// file per in-flight flow rather than one per throttle tick.
public enum FlowSpool {
    /// Where snapshots land. Sits beside the registry and the command channel under
    /// the shared `ipc` folder, so the whole cross-front-end contract is one location.
    public static var defaultDirectory: URL {
        ProxyRegistry.defaultDirectory
            .appendingPathComponent("ipc", isDirectory: true)
            .appendingPathComponent("flows", isDirectory: true)
    }

    /// Upper bound on retained snapshots, so a reader that never catches up cannot
    /// fill the disk. Mirrors the GUI's own 20k in-memory cap but stays far below it:
    /// the spool is a hand-off buffer, not the session history.
    public static let maxSnapshots = 4_000

    /// Writer side: the process that hosts the engine.
    public final class Writer {
        private let directory: URL
        private let lock = NSLock()
        /// Newest written file per flow, so the previous snapshot can be removed.
        private var latestFileByID: [UUID: URL] = [:]
        /// Insertion order of `latestFileByID`, for the retention cap.
        private var insertionOrder: [UUID] = []
        private var sequence: UInt64 = 0

        public init(directory: URL = FlowSpool.defaultDirectory) {
            self.directory = directory
        }

        /// Drop anything a previous run left behind, before the first snapshot.
        /// Stale files would otherwise be replayed by a reader as if just captured.
        public func reset() {
            lock.lock(); defer { lock.unlock() }
            latestFileByID.removeAll()
            insertionOrder.removeAll()
            sequence = 0
            FlowSpool.clear(directory: directory)
        }

        /// Persist one snapshot, replacing this flow's previous file.
        public func write(_ flow: Flow) {
            lock.lock(); defer { lock.unlock() }
            guard let data = FlowSpool.encode(flow) else { return }
            try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

            sequence += 1
            let name = String(format: "%012llu-%@.json", sequence, flow.id.uuidString)
            let url = directory.appendingPathComponent(name)
            // Atomic: a reader never observes a half-written snapshot.
            guard (try? data.write(to: url, options: .atomic)) != nil else { return }

            if let previous = latestFileByID[flow.id] {
                try? FileManager.default.removeItem(at: previous)
            } else {
                insertionOrder.append(flow.id)
            }
            latestFileByID[flow.id] = url
            enforceCap()
        }

        /// Remove every snapshot this run wrote, for a clean shutdown.
        public func clear() {
            lock.lock(); defer { lock.unlock() }
            latestFileByID.removeAll()
            insertionOrder.removeAll()
            FlowSpool.clear(directory: directory)
        }

        private func enforceCap() {
            guard latestFileByID.count > FlowSpool.maxSnapshots else { return }
            let overflow = latestFileByID.count - FlowSpool.maxSnapshots
            for id in insertionOrder.prefix(overflow) {
                if let url = latestFileByID.removeValue(forKey: id) {
                    try? FileManager.default.removeItem(at: url)
                }
            }
            insertionOrder.removeFirst(overflow)
        }
    }

    // MARK: - Reader side (the attaching front-end)

    /// Snapshots waiting to be consumed, oldest first. Only regular files this user
    /// owns are considered, matching the guard the command channel applies.
    public static func pendingURLs(directory: URL = FlowSpool.defaultDirectory) -> [URL] {
        let contents = (try? FileManager.default.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: [.isRegularFileKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return contents
            .filter { $0.pathExtension == "json" }
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
    }

    /// Decode one snapshot. Returns nil for a file that is gone or unreadable, which a
    /// concurrent writer can legitimately produce.
    public static func read(_ url: URL) -> Flow? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? ProxyRegistry.decoder.decode(Flow.self, from: data)
    }

    /// Delete a consumed snapshot. Safe because names are unique and never rewritten.
    public static func remove(_ url: URL) {
        try? FileManager.default.removeItem(at: url)
    }

    /// Remove every snapshot in the directory.
    public static func clear(directory: URL = FlowSpool.defaultDirectory) {
        for url in pendingURLs(directory: directory) {
            try? FileManager.default.removeItem(at: url)
        }
    }

    static func encode(_ flow: Flow) -> Data? {
        try? ProxyRegistry.encoder.encode(flow)
    }
}
