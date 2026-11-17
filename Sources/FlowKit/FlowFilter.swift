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
    case client(String)
    case domain(String)
    /// One connected emulator or device, selected by `adb` serial.
    case device(String)

    /// True for the Collections rows themselves, as opposed to an entry inside one.
    public var isCollection: Bool {
        switch self {
        case .all, .pinned, .saved: return true
        case .app, .client, .domain, .device: return false
        }
    }
}

/// The sidebar's two-level selection: which Collections row is open, and which entry
/// inside it is drilled into.
///
/// These live apart because they answer different questions. One slot for both meant a
/// click on a pinned or saved entry overwrote the collection that held it, dropping the
/// list back to All. `scope` is `nil` when no entry is drilled into, so the collection
/// alone decides what the table shows.
public struct SidebarNavigation: Equatable, Sendable {
    public var collection: SidebarSelection
    public var scope: SidebarSelection?

    public init(collection: SidebarSelection = .all, scope: SidebarSelection? = nil) {
        self.collection = collection
        self.scope = scope
    }

    /// The entity predicate to hand `FlowFilter`. A collection row is not a flow
    /// predicate — Pinned and Saved narrow by the marks instead — so it contributes none.
    public var flowScope: SidebarSelection {
        guard let scope, !scope.isCollection else { return .all }
        return scope
    }

    /// What the list highlights: the drilled-in entry when there is one, else the
    /// collection row.
    public var highlighted: SidebarSelection {
        scope ?? collection
    }

    /// Apply a click on a tagged sidebar row.
    ///
    /// A collection row opens that collection and drops any drill-down. An entry row
    /// narrows whichever collection is already open, leaving it open.
    public mutating func select(_ selection: SidebarSelection) {
        if selection.isCollection {
            collection = selection
            scope = nil
        } else {
            scope = selection
        }
    }

    /// Drop a drill-down that no longer resolves, keeping the collection open.
    public mutating func clearScope() {
        scope = nil
    }
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
        case .app(let client):
            guard let app = flow.clientApp else { return false }
            if app.id != client, app.bundleIdentifier != client, app.path != client,
               app.name.caseInsensitiveCompare(client) != .orderedSame {
                return false
            }
        case .client(let id):
            if flow.clientApp?.id != id { return false }
        case .domain(let hostName):
            if flow.host.caseInsensitiveCompare(hostName) != .orderedSame { return false }
        case .device(let serial):
            if flow.connectedDevice?.serial != serial { return false }
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
