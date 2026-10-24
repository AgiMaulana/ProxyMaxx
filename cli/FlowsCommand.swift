import Foundation
import FlowKit
import RuleKit

/// `proxymaxx-cli flows`: read the session the engine captured, narrowed the same way the
/// app's filter bar narrows its table. This is the pull half of the filters menu — the
/// engine stays neutral and the log stays complete, so an agent can retune focus as
/// often as it likes without restarting anything.
enum FlowsCommand {
    static func run(_ arguments: Arguments) async throws {
        let url = sessionLogURL(arguments)
        let mode = arguments.value("flow-mode") ?? "summary"
        guard mode == "summary" || mode == "full" else {
            throw CLIError("--flow-mode must be summary or full")
        }
        let filter = try makeFilter(arguments)
        let since = try parseSince(arguments.value("since"))
        let limit = try positiveInt(arguments, "limit")
        let asText = arguments.has("text")
        let follow = arguments.has("follow")
        let failOnMatch = arguments.has("fail-on-match")

        func emit(_ flow: Flow) {
            asText ? print(FlowFormat.text(flow)) : FlowFormat.emit(flow, mode: mode)
        }
        func selected(_ flow: Flow) -> Bool {
            if let since, flow.timing.start < since { return false }
            return filter.matches(flow)
        }

        guard follow else {
            var matched = SessionLog.read(url: url).filter(selected)
            // `--limit` keeps the newest N, then prints them oldest-first as captured.
            if let limit { matched = Array(matched.suffix(limit)) }
            for flow in matched { emit(flow) }
            if failOnMatch, !matched.isEmpty { exit(ExitCode.matchedFlows) }
            return
        }

        // Follow: replay what is already there, then tail new lines until interrupted or
        // the engine stops. The log keeps every snapshot the engine emitted, but a reader
        // promises one line per flow, so `Follower` holds a flow until its closing
        // snapshot and surfaces it once; `--limit` therefore counts flows, not snapshots.
        // A flow still open at the end is surfaced from its latest snapshot, which is what
        // a later non-following read would show.
        let interrupt = InterruptFlag()
        interrupt.install()
        var follower = SessionLog.Follower(url: url)
        var emitted = 0

        /// Print the selected flows, stopping as soon as `--limit` is reached. Returns
        /// true when the limit was hit, so the caller can exit without reading further.
        func emitUpToLimit(_ flows: [Flow]) -> Bool {
            for flow in flows where selected(flow) {
                emit(flow)
                emitted += 1
                if let limit, emitted >= limit { return true }
            }
            return false
        }

        while !interrupt.isInterrupted {
            if emitUpToLimit(follower.poll()) {
                if failOnMatch { exit(ExitCode.matchedFlows) }
                return
            }
            // Nothing left to write once no process owns the engine.
            if ProxyRegistry.read() == nil { break }
            try? await Task.sleep(for: .milliseconds(150))
        }
        // Read the tail and close out whatever never finished, so the last flows the
        // engine wrote are not dropped.
        _ = emitUpToLimit(follower.finish())
        if failOnMatch, emitted > 0 { exit(ExitCode.matchedFlows) }
    }

    // MARK: - Flag parsing

    /// Build the same `FlowFilter` the app builds from its filter bar. Host, app, pinned
    /// and saved all describe one sidebar choice, so at most one may be given.
    private static func makeFilter(_ arguments: Arguments) throws -> FlowFilter {
        var filter = FlowFilter()
        if let text = arguments.value("filter") { filter.text = text }
        if let method = arguments.value("method") {
            guard let canonical = FlowFilter.methods.first(where: { $0.caseInsensitiveCompare(method) == .orderedSame }) else {
                throw CLIError("--method must be one of \(FlowFilter.methods.joined(separator: "|"))")
            }
            filter.method = canonical
        }
        filter.onlyErrors = try boolValue(arguments, "errors-only") ?? false

        var choices: [(flag: String, selection: SidebarSelection)] = []
        if let host = arguments.value("host") { choices.append(("--host", .domain(host))) }
        if let app = arguments.value("app") { choices.append(("--app", .app(app))) }
        if arguments.has("pinned") { choices.append(("--pinned", .pinned)) }
        if arguments.has("saved") { choices.append(("--saved", .saved)) }
        guard choices.count <= 1 else {
            throw CLIError("choose at most one of --host, --app, --pinned, --saved")
        }
        if let choice = choices.first { filter.sidebarSelection = choice.selection }
        return filter
    }

    /// `--since` accepts a duration (`30s`, `5m`, `2h`, `1d`) or bare seconds.
    private static func parseSince(_ raw: String?) throws -> Date? {
        guard let raw, !raw.isEmpty else { return nil }
        let multiplier: Double
        let numberPart: String
        switch raw.lowercased().last {
        case "s": multiplier = 1; numberPart = String(raw.dropLast())
        case "m": multiplier = 60; numberPart = String(raw.dropLast())
        case "h": multiplier = 3600; numberPart = String(raw.dropLast())
        case "d": multiplier = 86_400; numberPart = String(raw.dropLast())
        default: multiplier = 1; numberPart = raw
        }
        guard let value = Double(numberPart), value >= 0 else {
            throw CLIError("--since must be seconds or a duration like 30s, 5m, 2h, 1d")
        }
        return Date().addingTimeInterval(-value * multiplier)
    }

    private static func positiveInt(_ arguments: Arguments, _ name: String) throws -> Int? {
        guard let raw = arguments.value(name), !raw.isEmpty else { return nil }
        guard let value = Int(raw), value > 0 else {
            throw CLIError("--\(name) must be a positive integer")
        }
        return value
    }
}
