import Foundation

/// A capability ProxyMaxx exposes to plugins, as shown in consent and detail UI.
public struct PluginPermission: Identifiable, Equatable, Sendable {
    public let id: String
    public let name: String
    public let description: String

    public init(id: String, name: String, description: String) {
        self.id = id
        self.name = name
        self.description = description
    }
}

/// Central registry of supported permissions (docs/plugin-store-phase1.md §6).
///
/// ProxyMaxx controls this list; plugins cannot introduce or register their own, and
/// a manifest naming an unknown identifier is rejected at install time. Permissions
/// stay granular — read access never implies write or delete access.
/// `filesystem.read` is deliberately absent until an SDK feature actually needs it.
public enum PluginPermissionRegistry {
    public static let all: [PluginPermission] = [
        PluginPermission(
            id: "local-map.read",
            name: "Read Local Override rules",
            description: "View the Local Override (Map Local) rules configured in ProxyMaxx."
        ),
        PluginPermission(
            id: "local-map.create",
            name: "Create Local Override rules",
            description: "Add new Local Override (Map Local) rules."
        ),
        PluginPermission(
            id: "local-map.update",
            name: "Update Local Override rules",
            description: "Change or reorder existing Local Override (Map Local) rules."
        ),
        PluginPermission(
            id: "local-map.delete",
            name: "Delete Local Override rules",
            description: "Remove Local Override (Map Local) rules."
        ),
    ]

    private static let byID = Dictionary(uniqueKeysWithValues: all.map { ($0.id, $0) })

    public static func permission(id: String) -> PluginPermission? {
        byID[id]
    }

    public static func isSupported(_ id: String) -> Bool {
        byID[id] != nil
    }
}
