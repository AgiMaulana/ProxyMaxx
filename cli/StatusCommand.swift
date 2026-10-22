import Foundation
import RuleKit

/// One JSON object describing the current engine owner, for scripts and agents. Shared
/// by `proxymaxx-cli status` and the tail of `proxymaxx-cli stop` so both report the same shape.
enum StatusCommand {
    struct Report: Encodable {
        var running: Bool
        var owner: String?
        var pid: Int?
        var httpPort: Int?
        var socksPort: Int?
        var startedAt: Date?
    }

    static func current() -> Report {
        guard let entry = ProxyRegistry.read() else {
            return Report(running: false, owner: nil, pid: nil, httpPort: nil, socksPort: nil, startedAt: nil)
        }
        return Report(
            running: true,
            owner: entry.owner.rawValue,
            pid: entry.pid,
            httpPort: entry.httpPort,
            socksPort: entry.socksPort,
            startedAt: entry.startedAt
        )
    }

    static func printCurrent() {
        print(text())
    }

    static func text() -> String {
        // Same pinned strategy as ProxyRegistry, so the epoch representation matches the
        // file's rather than the 2001 reference date.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        guard let data = try? encoder.encode(current()) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
