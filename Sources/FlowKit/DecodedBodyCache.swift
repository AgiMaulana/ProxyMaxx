import Foundation

/// Cache of decoded flow bodies per flow revision.
///
/// Inflating compressed bodies (gzip, brotli, zstd) takes CPU time that should not
/// be paid repeatedly on every SwiftUI redraw. Decoded results are cached by flow id,
/// payload side (request vs. response), byte count, and revision.
public final class DecodedBodyCache: @unchecked Sendable {
    public static let shared = DecodedBodyCache()

    public struct Key: Hashable, Sendable {
        public let flowID: UUID
        public let isRequest: Bool
        public let revision: Int
        public let byteCount: Int
        public let encoding: String?

        public init(flowID: UUID, isRequest: Bool, revision: Int, byteCount: Int, encoding: String?) {
            self.flowID = flowID
            self.isRequest = isRequest
            self.revision = revision
            self.byteCount = byteCount
            self.encoding = encoding
        }
    }

    private let lock = NSLock()
    private var entries: [Key: Data?] = [:]
    private var order: [Key] = []
    private let capacity: Int

    public init(capacity: Int = 100) {
        self.capacity = capacity
    }

    /// Retrieve the cached decoded body, or decode and cache if missing.
    /// Returns nil if the payload is not compressed or cannot be decoded.
    public func decoded(
        data: Data,
        encoding: String?,
        flowID: UUID,
        revision: Int,
        isRequest: Bool
    ) -> Data? {
        guard let encoding, !encoding.isEmpty, !data.isEmpty else { return nil }
        let key = Key(
            flowID: flowID,
            isRequest: isRequest,
            revision: revision,
            byteCount: data.count,
            encoding: encoding
        )

        lock.lock()
        if let cached = entries[key] {
            lock.unlock()
            return cached
        }
        lock.unlock()

        let decodedData = ContentDecoding.decode(data, encoding: encoding)

        lock.lock()
        defer { lock.unlock() }
        if entries[key] == nil {
            if order.count >= capacity {
                let evicted = order.removeFirst()
                entries.removeValue(forKey: evicted)
            }
            order.append(key)
        }
        entries[key] = decodedData
        return decodedData
    }

    public func cachedEntry(
        flowID: UUID,
        isRequest: Bool,
        revision: Int,
        byteCount: Int,
        encoding: String?
    ) -> Data?? {
        let key = Key(
            flowID: flowID,
            isRequest: isRequest,
            revision: revision,
            byteCount: byteCount,
            encoding: encoding
        )
        lock.lock()
        defer { lock.unlock() }
        return entries[key]
    }

    public func clear() {
        lock.lock()
        defer { lock.unlock() }
        entries.removeAll()
        order.removeAll()
    }
}
