import Foundation

/// Typed authorization failures, mirroring the SDK error model in
/// docs/sdk-permission-api.md §7. Protected operations surface these to callers so
/// plugins never have to parse error strings.
public enum PluginPermissionError: Error, Equatable, Sendable {
    case unknownPlugin(String)
    case unknownPermission(String)
    /// The permission is not declared in the plugin's own manifest.
    case notDeclared(String)
    /// Declared and supported, but the user has not granted it.
    case notGranted(String)
    /// Permission state could not be verified; protected operations fail closed.
    case integrityFailure
    case storageFailed(String)
}

/// What the native consent sheet shows for one permission request
/// (docs/plugin-store-phase1.md §7.2).
public struct PluginConsentRequest: Identifiable, Equatable, Sendable {
    public let id: String
    public let pluginID: String
    public let pluginName: String
    public let permission: PluginPermission
    public let reason: String
    public let required: Bool

    public init(
        pluginID: String, pluginName: String, permission: PluginPermission, reason: String, required: Bool
    ) {
        self.id = "\(pluginID)|\(permission.id)"
        self.pluginID = pluginID
        self.pluginName = pluginName
        self.permission = permission
        self.reason = reason
        self.required = required
    }
}

/// Resolves permission decisions for plugins and owns the consent flow
/// (docs/plugin-store-phase1.md §7, §10).
///
/// ProxyMaxx is the only writer of decisions. The runner funnels plugin requests
/// through `request` so identity is host-supplied — a plugin process can never speak
/// for another plugin — and `authorize` is the primitive the Local Override boundary
/// calls before executing any protected operation. Concurrent `request` calls for the
/// same permission coalesce into one consent experience (docs/sdk-permission-api.md §5.5).
@MainActor
public final class PermissionManager: ObservableObject {
    /// Presents native consent and reports the user's decision. Set by the app; the
    /// injected closure keeps PluginKit UI-free and lets tests answer automatically.
    public typealias ConsentPresenting = (PluginConsentRequest) async -> Bool

    private let registry: PluginRegistry
    private let store: PermissionStore
    private var presentConsent: ConsentPresenting?
    private var pendingRequests: [String: Task<PluginPermissionStatus, Never>] = [:]

    public init(registry: PluginRegistry, store: PermissionStore) {
        self.registry = registry
        self.store = store
    }

    public func setConsentPresenter(_ presenter: ConsentPresenting?) {
        presentConsent = presenter
    }

    // MARK: - Enforcement

    /// The gate every protected Local Override operation passes. Throws unless the
    /// plugin exists, declares the permission, the host supports it, and the user has
    /// granted it. Revocation applies to the very next call (docs §10).
    public func authorize(pluginID: String, permissionID: String) throws {
        guard store.isTrustworthy else { throw PluginPermissionError.integrityFailure }
        guard let plugin = registry.plugin(id: pluginID) else {
            throw PluginPermissionError.unknownPlugin(pluginID)
        }
        guard plugin.manifest.permissions.contains(where: { $0.id == permissionID }) else {
            throw PluginPermissionError.notDeclared(permissionID)
        }
        guard PluginPermissionRegistry.isSupported(permissionID) else {
            throw PluginPermissionError.unknownPermission(permissionID)
        }
        guard store.status(pluginID: pluginID, permissionID: permissionID) == .granted else {
            throw PluginPermissionError.notGranted(permissionID)
        }
    }

    /// The SDK's `request` path: resolve an existing decision, or obtain consent.
    /// Denied permissions stay denied until the user changes the decision from the
    /// Plugin Store — a repeat request does not re-prompt (docs §7.3).
    public func request(pluginID: String, permissionID: String) async -> PluginPermissionStatus {
        let key = "\(pluginID)|\(permissionID)"
        if let running = pendingRequests[key] {
            return await running.value
        }
        let task = Task<PluginPermissionStatus, Never> { [weak self] () -> PluginPermissionStatus in
            guard let self else { return .notRequested }
            defer { self.pendingRequests.removeValue(forKey: key) }
            return await self.resolveRequest(pluginID: pluginID, permissionID: permissionID)
        }
        pendingRequests[key] = task
        return await task.value
    }

    // MARK: - Decisions from the Plugin Store UI

    /// Record an explicit grant from the details view (docs §8.2).
    public func grant(pluginID: String, permissionID: String) throws {
        try validateDecisionTarget(pluginID: pluginID, permissionID: permissionID)
        try store.record(pluginID: pluginID, permissionID: permissionID, status: .granted)
    }

    /// Record an explicit revocation. The next `authorize` for the permission fails
    /// from this moment on; running plugins re-check before protected operations.
    public func revoke(pluginID: String, permissionID: String) throws {
        try validateDecisionTarget(pluginID: pluginID, permissionID: permissionID)
        try store.record(pluginID: pluginID, permissionID: permissionID, status: .denied)
    }

    /// Current status of one declared permission, without triggering consent.
    public func status(pluginID: String, permissionID: String) -> PluginPermissionStatus {
        store.status(pluginID: pluginID, permissionID: permissionID)
    }

    /// Decisions for every permission a plugin declares, for the details view.
    public func statuses(for plugin: InstalledPlugin) -> [(declaration: PluginManifest.PermissionDeclaration, status: PluginPermissionStatus)] {
        plugin.manifest.permissions.map { ($0, store.status(pluginID: plugin.id, permissionID: $0.id)) }
    }

    /// Drop every decision belonging to one plugin. Used by uninstall (docs §5.4).
    public func removeDecisions(pluginID: String) throws {
        try store.removeDecisions(pluginID: pluginID)
    }

    /// True when decisions can be trusted for authorization right now. False after
    /// the store detected tampering or an unreadable file; the Plugin Store surfaces
    /// `integrityErrorDescription` in that case.
    public var isTrustworthy: Bool { store.isTrustworthy }

    public var integrityErrorDescription: String? { store.integrityError }

    // MARK: - Private

    private func validateDecisionTarget(pluginID: String, permissionID: String) throws {
        guard store.isTrustworthy else { throw PluginPermissionError.integrityFailure }
        guard let plugin = registry.plugin(id: pluginID) else {
            throw PluginPermissionError.unknownPlugin(pluginID)
        }
        guard plugin.manifest.permissions.contains(where: { $0.id == permissionID }) else {
            throw PluginPermissionError.notDeclared(permissionID)
        }
        guard PluginPermissionRegistry.isSupported(permissionID) else {
            throw PluginPermissionError.unknownPermission(permissionID)
        }
    }

    private func resolveRequest(pluginID: String, permissionID: String) async -> PluginPermissionStatus {
        // Fail closed: unverifiable state is reported as unavailable, never granted.
        guard store.isTrustworthy else { return .unavailable }
        guard let plugin = registry.plugin(id: pluginID),
              let declaration = plugin.manifest.permissions.first(where: { $0.id == permissionID }),
              let permission = PluginPermissionRegistry.permission(id: permissionID) else {
            return .unavailable
        }
        let current = store.status(pluginID: pluginID, permissionID: permissionID)
        switch current {
        case .granted, .denied, .unavailable:
            return current
        case .notRequested:
            guard let presentConsent else { return .notRequested }
            let request = PluginConsentRequest(
                pluginID: pluginID, pluginName: plugin.manifest.name,
                permission: permission, reason: declaration.reason, required: declaration.required
            )
            let granted = await presentConsent(request)
            let status: PluginPermissionStatus = granted ? .granted : .denied
            do {
                try store.record(pluginID: pluginID, permissionID: permissionID, status: status)
            } catch {
                return .unavailable
            }
            return status
        }
    }
}
