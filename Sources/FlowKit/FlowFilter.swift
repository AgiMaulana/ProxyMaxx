import Foundation

/// The one place a captured flow is tested against the user's narrowing choices.
///
/// The app binds its filter bar to this and the CLI parses its flags into the same
/// value, so "Errors only, POST, api.example.com" selects byte-identical rows whether
/// a person clicks it or an agent passes flags. Keeping it here rather than in the app
/// target is what stops the two front-ends from drifting.
public enum SidebarSelection: Hashable, Equatable, Sendable, Codable {
    case all
    case pinned
    case saved
    case app(String)
    case domain(String)
}

/// Text, method, error and sidebar filtering applied to the captured flow list.
public struct FlowFilter: Equatable, Sendable, Codable {
    public var text: String = ""
    public var method: String = "All"
    public var onlyErrors: Bool = false
    public var sidebarSelection: SidebarSelection = .all

    public static let methods = ["All", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "CONNECT"]

    public init(
        text: String = "",
        method: String = "All",
        onlyErrors: Bool = false,
        sidebarSelection: SidebarSelection = .all
    ) {
        self.text = text
        self.method = method
        self.onlyErrors = onlyErrors
        self.sidebarSelection = sidebarSelection
    }

    /// True when this flow passes every active predicate. Single-flow form so streaming
    /// callers can decide per flow without re-filtering the whole list.
    public func matches(_ flow: Flow) -> Bool {
        if onlyErrors, flow.error == nil, (flow.statusCode ?? 0) < 400 {
            return false
        }
        if method != "All", flow.method.caseInsensitiveCompare(method) != .orderedSame {
            return false
        }
        switch sidebarSelection {
        case .all:
            break
        case .pinned:
            if !flow.isPinned { return false }
        case .saved:
            if flow.response == nil && flow.error == nil { return false }
        case .app(let appName):
            if flow.clientApp != appName { return false }
        case .domain(let hostName):
            if flow.host.caseInsensitiveCompare(hostName) != .orderedSame { return false }
        }

        guard !text.isEmpty else { return true }
        let needle = text.lowercased()
        return flow.url.lowercased().contains(needle)
            || flow.host.lowercased().contains(needle)
            || flow.method.lowercased().contains(needle)
            || (flow.statusCode.map(String.init)?.contains(needle) ?? false)
    }

    public func apply(to flows: [Flow]) -> [Flow] {
        flows.filter(matches)
    }
}
