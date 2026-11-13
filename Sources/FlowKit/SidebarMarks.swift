import Foundation
import Combine

/// What a sidebar mark can point at: a device, an app, or a host.
public enum SidebarEntityKind: String, Codable, Sendable, CaseIterable {
    case device
    case app
    case domain
}

/// One pinnable or savable entry in the sidebar.
///
/// Identity is `kind` + `key`, where `key` is an identifier that survives a restart: the
/// `adb` serial, `ClientApp.id`, or the host. `label` is the display name frozen when the
/// mark was made, so a marked entry still reads correctly when it has no traffic yet, or its
/// emulator is stopped and it no longer appears in the live device list.
public struct SidebarEntity: Codable, Sendable, Hashable, Identifiable {
    public let kind: SidebarEntityKind
    public let key: String
    public var label: String

    public init(kind: SidebarEntityKind, key: String, label: String) {
        self.kind = kind
        self.key = key
        self.label = label
    }

    public static func device(serial: String, label: String) -> SidebarEntity {
        SidebarEntity(kind: .device, key: serial, label: label)
    }

    public static func app(_ app: ClientApp) -> SidebarEntity {
        SidebarEntity(kind: .app, key: app.id, label: app.name)
    }

    public static func domain(_ host: String) -> SidebarEntity {
        SidebarEntity(kind: .domain, key: host, label: host)
    }

    public var id: String { "\(kind.rawValue):\(key)" }

    /// Two marks are the same entry when they name the same kind and identifier. A label
    /// that changed between runs must not turn one entry into two.
    public static func == (lhs: SidebarEntity, rhs: SidebarEntity) -> Bool {
        lhs.kind == rhs.kind && lhs.key == rhs.key
    }

    public func hash(into hasher: inout Hasher) {
        hasher.combine(kind)
        hasher.combine(key)
    }

    /// True when this marked entry owns the given flow.
    public func matches(_ flow: Flow) -> Bool {
        switch kind {
        case .device: return flow.connectedDevice?.serial == key
        case .app: return flow.clientApp?.id == key
        case .domain: return flow.host.caseInsensitiveCompare(key) == .orderedSame
        }
    }
}

/// The on-disk shape of the sidebar marks. Arrays, not sets, so the file is order-stable and
/// the list a person sees is the list that was written.
public struct SidebarMarksFile: Codable, Equatable, Sendable {
    public var pinned: [SidebarEntity]
    public var saved: [SidebarEntity]

    public init(pinned: [SidebarEntity] = [], saved: [SidebarEntity] = []) {
        self.pinned = pinned
        self.saved = saved
    }
}

/// Observable set of the sidebar's pinned and saved entries, persisted to disk.
///
/// Follows `RuleStore`: load once at init, debounce a save after each change, and offer an
/// explicit flush for the app's quit path. Nothing outside the app writes this file, so there
/// is no external-revision reconciliation.
@MainActor
public final class SidebarMarks: ObservableObject {
    @Published public private(set) var pinned: [SidebarEntity] = []
    @Published public private(set) var saved: [SidebarEntity] = []

    /// Where the marks live on disk; `nil` keeps the store in memory only, which is what
    /// tests want so they never read each other's leftovers.
    private let persistenceURL: URL?
    private var cancellables = Set<AnyCancellable>()

    public init(persistenceURL: URL? = nil) {
        self.persistenceURL = persistenceURL
        if let persistenceURL { loadSavedState(from: persistenceURL) }
        objectWillChange
            .debounce(for: .milliseconds(250), scheduler: DispatchQueue.main)
            .sink { [weak self] _ in self?.save() }
            .store(in: &cancellables)
    }

    /// Read back a previous run's marks. A missing or corrupt file leaves the store empty.
    private func loadSavedState(from url: URL) {
        guard let data = try? Data(contentsOf: url),
              let state = try? JSONDecoder().decode(SidebarMarksFile.self, from: data) else { return }
        pinned = state.pinned
        saved = state.saved
    }

    private func save() {
        guard let persistenceURL else { return }
        guard let data = try? JSONEncoder().encode(currentMarksFile()) else { return }
        try? FileManager.default.createDirectory(
            at: persistenceURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try? data.write(to: persistenceURL, options: .atomic)
    }

    /// Write the current marks now instead of waiting out the debounce. The app calls this on
    /// quit so the last change before ⌘Q is not dropped.
    public func flushToDisk() {
        save()
    }

    public func currentMarksFile() -> SidebarMarksFile {
        SidebarMarksFile(pinned: pinned, saved: saved)
    }

    // MARK: - Query

    public func isPinned(_ entity: SidebarEntity) -> Bool { pinned.contains(entity) }
    public func isSaved(_ entity: SidebarEntity) -> Bool { saved.contains(entity) }

    /// Membership by kind and key alone, for callers that hold an identifier but not a label.
    public func isPinned(_ kind: SidebarEntityKind, _ key: String) -> Bool {
        isPinned(SidebarEntity(kind: kind, key: key, label: ""))
    }

    public func isSaved(_ kind: SidebarEntityKind, _ key: String) -> Bool {
        isSaved(SidebarEntity(kind: kind, key: key, label: ""))
    }

    /// True when the flow belongs to any pinned entry.
    public func isPinned(_ flow: Flow) -> Bool { pinned.contains { $0.matches(flow) } }
    /// True when the flow belongs to any saved entry.
    public func isSaved(_ flow: Flow) -> Bool { saved.contains { $0.matches(flow) } }

    // MARK: - Mutation

    public func togglePin(_ entity: SidebarEntity) {
        pinned = Self.toggled(pinned, entity)
    }

    public func toggleSave(_ entity: SidebarEntity) {
        saved = Self.toggled(saved, entity)
    }

    private static func toggled(_ list: [SidebarEntity], _ entity: SidebarEntity) -> [SidebarEntity] {
        var list = list
        if let index = list.firstIndex(of: entity) {
            list.remove(at: index)
        } else {
            list.append(entity)
        }
        return list
    }
}
