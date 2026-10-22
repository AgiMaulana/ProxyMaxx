import Foundation

/// Wall-clock marks gathered while a single flow transits the proxy.
public struct FlowTiming: Codable, Hashable, Sendable {
    public var start: Date
    public var dnsDone: Date?
    public var connectDone: Date?
    public var tlsDone: Date?
    public var requestSent: Date?
    public var responseStarted: Date?
    public var end: Date?

    public init(start: Date = Date()) {
        self.start = start
    }

    private func delta(_ from: Date?, _ to: Date?) -> TimeInterval? {
        guard let from, let to else { return nil }
        return to.timeIntervalSince(from)
    }

    public var total: TimeInterval? { delta(start, end) }

    public var dnsDuration: TimeInterval? { delta(start, dnsDone) }

    public var connectDuration: TimeInterval? { delta(dnsDone ?? start, connectDone) }

    public var tlsDuration: TimeInterval? { delta(connectDone, tlsDone) }

    public var requestDuration: TimeInterval? { delta(tlsDone ?? connectDone ?? start, requestSent) }

    /// Time to first byte of the response (server latency).
    public var latency: TimeInterval? { delta(requestSent, responseStarted) }

    public var responseDuration: TimeInterval? { delta(responseStarted, end) }
}
