import Foundation
import FlowKit

/// Append-only record of one capture session, readable by any number of processes.
///
/// This is deliberately *not* `FlowSpool`. The spool is a single-consumer hand-off:
/// the first reader deletes each snapshot it consumes, so it can move a live session
/// between two front-ends exactly once. That makes it useless for an agent that wants
/// to ask "what did I capture?" repeatedly, or for a person reading in the window while
/// an agent reads the same file — the two would steal from each other.
///
/// The session log is the opposite contract: the host appends one JSON object per line
/// and never rewrites it; readers only ever read. Whoever hosts the engine starts the
/// log fresh (a new run is a new session) and appends every snapshot thereafter, so the
/// file outlives the process that wrote it. Retention is the writer's job — readers
/// never delete — which is what lets the file serve many readers at once.
///
/// Layout: `…/ProxyMaxx/session.ndjson`
public enum SessionLog {
    /// Where the session lands. A sibling of the registry and the rule file, so the
    /// whole contract is one directory an agent can point `--out` at.
    public static var defaultURL: URL {
        ProxyRegistry.defaultDirectory.appendingPathComponent("session.ndjson")
    }

    /// Writer side: the process that hosts the engine.
    public final class Writer {
        public let url: URL
        /// Soft cap on retained lines. When exceeded the log is compacted down to its
        /// newest half in one atomic rewrite, so a long session cannot fill the disk.
        public var maxLines: Int
        private let lock = NSLock()
        /// Lines appended since the last reset, so the cap is checked without rescanning.
        private var lineCount = 0

        public init(url: URL = SessionLog.defaultURL, maxLines: Int = 50_000) {
            self.url = url
            self.maxLines = maxLines
        }

        /// Start a fresh session: truncate whatever a previous run left behind, so a
        /// reader never replays an old session as if it were just captured.
        public func reset() {
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            _ = FileManager.default.createFile(atPath: url.path, contents: Data())
            lineCount = 0
        }

        /// Append one snapshot as a single NDJSON line. The trailing newline is written
        /// in the same call, so a follower only ever consumes complete lines.
        public func append(_ flow: Flow) {
            guard let payload = SessionLog.encodeLine(flow) else { return }
            lock.lock(); defer { lock.unlock() }
            try? FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            if !FileManager.default.fileExists(atPath: url.path) {
                FileManager.default.createFile(atPath: url.path, contents: nil)
            }
            guard let handle = try? FileHandle(forWritingTo: url) else { return }
            defer { try? handle.close() }
            _ = try? handle.seekToEnd()
            try? handle.write(contentsOf: payload + Data("\n".utf8))
            lineCount += 1
            if lineCount > maxLines { compact() }
        }

        /// Keep only the newest half of the log, in one atomic replace. A follower
        /// notices the shrink (its offset now exceeds the file) and restarts from zero.
        private func compact() {
            guard let data = try? Data(contentsOf: url) else { return }
            let lines = data.split(separator: 0x0A, omittingEmptySubsequences: true)
            let keep = lines.suffix(maxLines / 2)
            var rewritten = Data()
            for line in keep {
                rewritten.append(contentsOf: line)
                rewritten.append(0x0A)
            }
            try? rewritten.write(to: url, options: .atomic)
            lineCount = keep.count
        }
    }

    // MARK: - Reader side

    /// Every flow in the log, latest snapshot per id, in first-seen order. The engine
    /// emits several snapshots per flow (head, throttled body, completion); collapsing
    /// them by id is what makes this read like the app's one-row-per-flow table.
    public static func read(url: URL = defaultURL) -> [Flow] {
        guard let data = try? Data(contentsOf: url) else { return [] }
        return decode(data)
    }

    /// Read complete lines from a byte offset, for `--follow`. Returns the flows found
    /// and the offset to pass next time. An offset past the end means the log was
    /// truncated or compacted, so reading restarts from the beginning.
    ///
    /// Each call collapses the snapshots it sees, but nothing carries that collapse from
    /// one call to the next, so a tail that polls repeatedly can surface the same flow
    /// again when its snapshots straddle two polls. A tail that must promise one line per
    /// flow drives `Follower` instead, which keeps that state between reads.
    public static func read(url: URL = defaultURL, fromOffset offset: UInt64) -> (flows: [Flow], offset: UInt64) {
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: url.path),
              let size = (attributes[.size] as? NSNumber)?.uint64Value
        else { return ([], 0) }

        var start = offset
        if start > size { start = 0 }
        guard let handle = try? FileHandle(forReadingFrom: url) else { return ([], start) }
        defer { try? handle.close() }
        _ = try? handle.seek(toOffset: start)
        let data = (try? handle.readToEnd()) ?? Data()

        // Only consume up to the last newline: a line still being written stays for the
        // next poll rather than being decoded as a truncated flow.
        guard let lastNewline = data.lastIndex(of: 0x0A) else { return ([], start) }
        let complete = data[data.startIndex...lastNewline]
        return (decode(Data(complete)), start + UInt64(complete.count))
    }

    /// A long-lived reader that tails the log and surfaces each flow exactly once.
    ///
    /// `read(fromOffset:)` collapses the snapshots inside one call, which is not enough
    /// for a tail: the engine emits a flow's snapshots across several polls (request,
    /// response head, throttled body, completion), so the same flow would be printed
    /// again, each time with a partially filled line. This type carries the collapse
    /// state across polls and holds a flow back until its closing snapshot
    /// (`timing.end`), so a follower prints the same line a one-shot `read` would.
    ///
    /// It also survives compaction: the log may rewrite itself smaller, which sends the
    /// byte offset back to zero, and the ids already surfaced are what stop the replayed
    /// lines from being printed a second time.
    public struct Follower {
        public let url: URL
        /// Byte offset into the log, advanced on every poll.
        private var offset: UInt64 = 0
        /// Flows seen but not yet closed, newest snapshot per id, in the order they first
        /// appeared. Closed flows are removed as they are surfaced.
        private var inFlight: [UUID: Flow] = [:]
        /// Ids in `inFlight`, plus the ids already surfaced. Kept as a list because a
        /// dictionary's order is not the capture order a reader expects.
        private var order: [UUID] = []
        /// Ids already returned, so a replay after compaction cannot print them again.
        private var surfaced: Set<UUID> = []

        public init(url: URL = SessionLog.defaultURL) {
            self.url = url
        }

        /// Read whatever is new and return the flows that closed since the last poll, in
        /// the order their closing snapshots arrived. Each flow appears at most once.
        public mutating func poll() -> [Flow] {
            let (flows, nextOffset) = SessionLog.read(url: url, fromOffset: offset)
            offset = nextOffset
            var closed: [Flow] = []
            for flow in flows {
                // A flow already surfaced is a replayed line (compaction sent the offset
                // back to zero), not new traffic.
                guard !surfaced.contains(flow.id) else { continue }
                if inFlight[flow.id] == nil { order.append(flow.id) }
                inFlight[flow.id] = flow
                // No closing snapshot yet: hold the flow, so the caller never prints an
                // interim line missing the body and the duration.
                guard flow.timing.end != nil else { continue }
                closed.append(flow)
                inFlight.removeValue(forKey: flow.id)
                surfaced.insert(flow.id)
            }
            return closed
        }

        /// Read whatever is left and return every flow not yet surfaced: the ones that
        /// closed since the last poll, then the ones still open, newest snapshot each.
        /// Call once on shutdown.
        ///
        /// It reads again rather than only draining memory, because the engine can write
        /// a closing snapshot between the last poll and the moment it stops owning the
        /// engine — without this read, that flow would be lost. Keeping a never-closing
        /// flow is the other half: the request was captured, so it is printed from its
        /// latest snapshot, which is what a later non-following read would show.
        public mutating func finish() -> [Flow] {
            var ready = poll()
            for id in order {
                guard let flow = inFlight.removeValue(forKey: id) else { continue }
                guard surfaced.insert(id).inserted else { continue }
                ready.append(flow)
            }
            return ready
        }
    }

    /// Decode NDJSON into flows, collapsing repeat snapshots of the same flow onto its
    /// latest content while keeping the order each flow first appeared in.
    private static func decode(_ data: Data) -> [Flow] {
        var order: [UUID] = []
        var latest: [UUID: Flow] = [:]
        for line in data.split(separator: 0x0A, omittingEmptySubsequences: true) {
            guard let flow = try? ProxyRegistry.decoder.decode(Flow.self, from: Data(line)) else { continue }
            if latest[flow.id] == nil { order.append(flow.id) }
            latest[flow.id] = flow
        }
        return order.compactMap { latest[$0] }
    }

    static func encodeLine(_ flow: Flow) -> Data? {
        try? ProxyRegistry.encoder.encode(flow)
    }
}
