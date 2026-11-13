import SwiftUI
import PluginKit
import RuleKit
import UniformTypeIdentifiers

// MARK: - Coordinator

/// App-side owner of the Plugin Store subsystem: the plugin registry, the permission
/// manager, and the runner. Also answers permission requests raised by running
/// plugins with the native consent sheet (docs/plugin-store-phase1.md §7.2), one at
/// a time in arrival order.
@MainActor
final class PluginCoordinator: ObservableObject {
    let registry = PluginRegistry(directory: PluginRegistry.defaultDirectory)
    let permissionStore = PermissionStore()
    let permissionManager: PermissionManager
    let runner: PluginRunner

    /// The consent sheet currently waiting on the user, if any.
    @Published private(set) var activeConsentRequest: PluginConsentRequest?

    private struct QueuedConsent {
        let request: PluginConsentRequest
        let continuation: CheckedContinuation<Bool, Never>
    }

    private var consentQueue: [QueuedConsent] = []
    private var consentContinuation: CheckedContinuation<Bool, Never>?
    /// Errors surfaced by install/uninstall when the caller has no alert of its own.
    @Published var lastError: String?

    init() {
        permissionManager = PermissionManager(registry: registry, store: permissionStore)
        runner = PluginRunner(permissionManager: permissionManager)
        permissionManager.setConsentPresenter { [weak self] request in
            guard let self else { return false }
            return await self.presentConsent(request)
        }
    }

    /// The permission id the Local Override boundary requires for one operation.
    /// Kept here so the boundary's operation enum and the registry cannot drift.
    static func permissionID(for operation: LocalMapOperation) -> String {
        switch operation {
        case .read: return "local-map.read"
        case .create: return "local-map.create"
        case .update: return "local-map.update"
        case .delete: return "local-map.delete"
        }
    }

    /// The runner must not outlive the process; called on quit.
    func stopRunningPlugins() {
        runner.stopAll()
    }

    /// Remove a plugin end to end: stop it, drop its decisions, uninstall.
    func uninstall(_ plugin: InstalledPlugin) {
        runner.stop(plugin.id)
        do {
            try permissionManager.removeDecisions(pluginID: plugin.id)
            try registry.uninstall(id: plugin.id)
        } catch {
            lastError = error.localizedDescription
        }
    }

    // MARK: Consent flow

    private func presentConsent(_ request: PluginConsentRequest) async -> Bool {
        await withCheckedContinuation { continuation in
            consentQueue.append(QueuedConsent(request: request, continuation: continuation))
            showNextConsentIfNeeded()
        }
    }

    private func showNextConsentIfNeeded() {
        guard consentContinuation == nil, !consentQueue.isEmpty else { return }
        let next = consentQueue.removeFirst()
        consentContinuation = next.continuation
        activeConsentRequest = next.request
    }

    /// Resolve the visible consent sheet. Called by the sheet's buttons; an
    /// interactive dismissal arrives as `granted = false`.
    func resolveConsent(granted: Bool) {
        guard let continuation = consentContinuation else { return }
        consentContinuation = nil
        activeConsentRequest = nil
        continuation.resume(returning: granted)
        showNextConsentIfNeeded()
    }
}

// MARK: - Plugin Store

/// The Plugin Store window: installed plugins, install-from-file, and entry into the
/// per-plugin details (docs/plugin-store-phase1.md §5, §8.1).
struct PluginStoreView: View {
    @ObservedObject var coordinator: PluginCoordinator
    @State private var selectedPluginID: String?
    @State private var installPreview: PluginInstallPreview?
    @State private var detailsPluginID: String?
    @State private var pluginToRemove: InstalledPlugin?
    @State private var errorMessage: String?

    var body: some View {
        VStack(spacing: 0) {
            if let warning = coordinator.permissionStore.integrityError {
                integrityBanner(warning)
                Divider()
            }
            if coordinator.registry.installedPlugins.isEmpty {
                emptyState
            } else {
                pluginTable
                Divider()
                footer
            }
        }
        .frame(minWidth: 760, idealWidth: 880, maxWidth: 880,
               minHeight: 420, idealHeight: 480, maxHeight: 480)
        .sheet(item: $installPreview) { preview in
            PluginInstallPreviewView(preview: preview) { result in
                switch result {
                case .confirmed(let archiveURL):
                    installConfirmed(from: archiveURL)
                case .cancelled:
                    installPreview = nil
                }
            }
        }
        .sheet(isPresented: Binding(
            get: { detailsPluginID != nil },
            set: { if !$0 { detailsPluginID = nil } }
        )) {
            if let pluginID = detailsPluginID,
               let plugin = coordinator.registry.plugin(id: pluginID) {
                PluginDetailsView(coordinator: coordinator, plugin: plugin)
            }
        }
        .confirmationDialog(
            "plugin.details.uninstallTitle",
            isPresented: Binding(
                get: { pluginToRemove != nil },
                set: { if !$0 { pluginToRemove = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("plugin.details.uninstall", role: .destructive) {
                if let plugin = pluginToRemove {
                    coordinator.uninstall(plugin)
                    selectedPluginID = nil
                }
                pluginToRemove = nil
            }
            Button("common.cancel", role: .cancel) { pluginToRemove = nil }
        } message: {
            Text(L10n.format("plugin.details.uninstallMessage", pluginToRemove?.name ?? ""))
        }
        .alert("common.error", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .alert("common.error", isPresented: Binding(
            get: { coordinator.lastError != nil },
            set: { if !$0 { coordinator.lastError = nil } }
        )) {
            Button("common.ok", role: .cancel) { coordinator.lastError = nil }
        } message: {
            Text(coordinator.lastError ?? "")
        }
        .onChange(of: coordinator.registry.installedPlugins) { _, plugins in
            // Selection must not outlive its plugin (details sheet, uninstall, etc.).
            selectedPluginID = plugins.first { $0.id == selectedPluginID }?.id
        }
    }

    private func integrityBanner(_ warning: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("plugin.store.integrityTitle").font(.headline)
                Text(warning).font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
        }
        .padding(12)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "puzzlepiece.extension")
                .font(.system(size: 40))
                .foregroundStyle(.secondary)
            Text("plugin.store.emptyTitle").font(.headline)
            Text("plugin.store.emptyMessage")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Button("plugin.store.installFromPackage") { chooseInstall() }
                .buttonStyle(.borderedProminent)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var pluginTable: some View {
        Table(coordinator.registry.installedPlugins, selection: $selectedPluginID) {
            TableColumn("plugin.store.table.name") { plugin in
                Text(plugin.manifest.name)
            }
            TableColumn("plugin.store.table.version") { plugin in
                Text(plugin.manifest.version).monospacedDigit()
            }
            TableColumn("plugin.store.table.author") { plugin in
                Text(plugin.manifest.author).foregroundStyle(.secondary)
            }
            TableColumn("plugin.store.table.permissions") { plugin in
                Text(L10n.format("plugin.store.table.permissionCount", plugin.manifest.permissions.count))
                    .foregroundStyle(.secondary)
            }
            TableColumn("plugin.store.table.status") { plugin in
                if coordinator.runner.isRunning(plugin.id) {
                    Label("plugin.details.running", systemImage: "play.circle.fill")
                        .foregroundStyle(.green)
                } else {
                    Text("plugin.details.stopped").foregroundStyle(.secondary)
                }
            }
        }
    }

    private var footer: some View {
        HStack {
            Text(L10n.format("plugin.store.installedCount", coordinator.registry.installedPlugins.count))
                .font(.callout)
                .foregroundStyle(.secondary)
            Spacer()
            Button("plugin.store.details") { detailsPluginID = selectedPluginID }
                .disabled(selectedPluginID == nil)
            Button("plugin.store.installFromPackage") { chooseInstall() }
        }
        .padding(12)
    }

    private func chooseInstall() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "pxplugin") ?? .zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let manifest = try PluginPackageArchive.inspect(url)
            installPreview = PluginInstallPreview(archiveURL: url, manifest: manifest)
        } catch {
            errorMessage = error.localizedDescription
        }
    }

    private func installConfirmed(from archiveURL: URL) {
        installPreview = nil
        do {
            let plugin = try coordinator.registry.install(from: archiveURL)
            selectedPluginID = plugin.id
            detailsPluginID = plugin.id
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// Wrapper for the install preview sheet.
struct PluginInstallPreview: Identifiable {
    let archiveURL: URL
    let manifest: PluginManifest

    var id: String { manifest.id }
}

/// Result of the install preview sheet: either confirm the archive or cancel.
enum PluginInstallDecision {
    case confirmed(URL)
    case cancelled
}

/// The installation preview (docs/plugin-store-phase1.md §5.3): metadata plus the
/// permission split the user is about to be asked about, with the standing rule that
/// installing grants nothing.
struct PluginInstallPreviewView: View {
    let preview: PluginInstallPreview
    let onDecision: (PluginInstallDecision) -> Void

    var body: some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 6) {
                Text("plugin.install.title").font(.title2).bold()
                Text(preview.manifest.name).font(.title3)
                Text(L10n.format(
                    "plugin.install.metadata",
                    preview.manifest.version, preview.manifest.author
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                if !preview.manifest.description.isEmpty {
                    Text(preview.manifest.description)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    permissionSection(
                        "plugin.install.requiredPermissions",
                        preview.manifest.permissions.filter(\.required)
                    )
                    permissionSection(
                        "plugin.install.optionalPermissions",
                        preview.manifest.permissions.filter { !$0.required }
                    )
                }
                .padding(16)
            }

            Divider()

            HStack {
                Text("plugin.install.note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("common.cancel") { onDecision(.cancelled) }
                    .keyboardShortcut(.cancelAction)
                Button("plugin.install.confirm") { onDecision(.confirmed(preview.archiveURL)) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
            .padding(12)
        }
        .frame(width: 640, height: 480)
    }

    @ViewBuilder
    private func permissionSection(_ title: String, _ declarations: [PluginManifest.PermissionDeclaration]) -> some View {
        if !declarations.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text(title).font(.headline)
                ForEach(declarations, id: \.id) { declaration in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(PluginPermissionRegistry.permission(id: declaration.id)?.name ?? declaration.id)
                            .font(.callout)
                        Text(declaration.reason)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                    }
                    .padding(.leading, 4)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

// MARK: - Plugin details

/// The per-plugin details view (docs/plugin-store-phase1.md §8.2): metadata, declared
/// permissions with current decisions and grant/revoke, runtime controls, uninstall.
struct PluginDetailsView: View {
    @ObservedObject var coordinator: PluginCoordinator
    let plugin: InstalledPlugin

    @ObservedObject private var permissionStore: PermissionStore
    @ObservedObject private var runner: PluginRunner
    @Environment(\.dismiss) private var dismissSheet
    @State private var confirmUninstall = false

    init(coordinator: PluginCoordinator, plugin: InstalledPlugin) {
        self.coordinator = coordinator
        self.plugin = plugin
        self.permissionStore = coordinator.permissionStore
        self.runner = coordinator.runner
    }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    metadataSection
                    permissionsSection
                    runtimeSection
                }
                .padding(16)
            }
            Divider()
            HStack {
                Button("plugin.details.uninstall", role: .destructive) { confirmUninstall = true }
                Spacer()
                Button("common.done") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
            .padding(12)
        }
        .frame(width: 720, height: 560)
        .confirmationDialog(
            "plugin.details.uninstallTitle",
            isPresented: $confirmUninstall,
            titleVisibility: .visible
        ) {
            Button("plugin.details.uninstall", role: .destructive) {
                dismiss()
                coordinator.uninstall(plugin)
            }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(L10n.format("plugin.details.uninstallMessage", plugin.name))
        }
    }

    private func dismiss() {
        dismissSheet()
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            Text(plugin.manifest.name).font(.title2).bold()
            Text(plugin.manifest.version)
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()
            Spacer()
            if runner.isRunning(plugin.id) {
                Label("plugin.details.running", systemImage: "play.circle.fill")
                    .foregroundStyle(.green)
            }
        }
        .padding(16)
    }

    private var metadataSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("plugin.details.metadata").font(.headline)
            Text(plugin.manifest.author)
                .font(.callout)
                .foregroundStyle(.secondary)
            if !plugin.manifest.description.isEmpty {
                Text(plugin.manifest.description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Text(L10n.format("plugin.details.installedAt", plugin.installedAt.formatted(date: .long, time: .standard)))
                .font(.footnote)
                .foregroundStyle(.secondary)
            Text(L10n.format("plugin.details.sdk", plugin.manifest.sdkVersion, PluginSDK.version))
                .font(.footnote)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var permissionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("plugin.details.permissions").font(.headline)
            ForEach(coordinator.permissionManager.statuses(for: plugin), id: \.declaration.id) { entry in
                permissionRow(entry.declaration, entry.status)
                Divider()
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func permissionRow(
        _ declaration: PluginManifest.PermissionDeclaration, _ status: PluginPermissionStatus
    ) -> some View {
        let permission = PluginPermissionRegistry.permission(id: declaration.id)
        return HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Text(permission?.name ?? declaration.id).font(.callout)
                    Text(declaration.required ? "plugin.details.required" : "plugin.details.optional")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(declaration.required ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.14))
                        .clipShape(Capsule())
                }
                if let description = permission?.description {
                    Text(description)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Text(L10n.format("plugin.details.declaredReason", declaration.reason))
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            statusChip(status)
            switch status {
            case .granted:
                Button("plugin.details.revoke") {
                    perform { try coordinator.permissionManager.revoke(pluginID: plugin.id, permissionID: declaration.id) }
                }
            case .denied, .notRequested:
                Button("plugin.details.grant") {
                    perform { try coordinator.permissionManager.grant(pluginID: plugin.id, permissionID: declaration.id) }
                }
            case .unavailable:
                EmptyView()
            }
        }
    }

    private func statusChip(_ status: PluginPermissionStatus) -> some View {
        let (key, color): (String, Color) = switch status {
        case .granted: ("plugin.status.granted", .green)
        case .denied: ("plugin.status.denied", .red)
        case .notRequested: ("plugin.status.notRequested", .secondary)
        case .unavailable: ("plugin.status.unavailable", .orange)
        }
        return Text(key)
            .font(.caption)
            .fontWeight(.semibold)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(color.opacity(0.16))
            .foregroundStyle(color == .secondary ? Color.secondary : color)
            .clipShape(Capsule())
    }

    private var runtimeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("plugin.details.runtime").font(.headline)
            HStack {
                if runner.isRunning(plugin.id) {
                    Button("plugin.details.stop") { runner.stop(plugin.id) }
                    if let state = runner.runState(for: plugin.id) {
                        Text(L10n.format("plugin.details.pid", state.pid))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                } else {
                    Button("plugin.details.run") { startPlugin() }
                }
            }
            if let exit = runner.lastExitDescription[plugin.id] {
                Text(exit)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func startPlugin() {
        do {
            try runner.start(plugin, registry: coordinator.registry)
        } catch {
            coordinator.lastError = error.localizedDescription
        }
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { coordinator.lastError = error.localizedDescription }
    }
}

// MARK: - Consent

/// Native permission consent (docs/plugin-store-phase1.md §7.2). One permission per
/// sheet; the user decides each permission independently.
struct PluginConsentView: View {
    let request: PluginConsentRequest
    let onResolve: (Bool) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("plugin.consent.title").font(.title2).bold()
            Text(L10n.format("plugin.consent.subtitle", request.pluginName))
                .font(.callout)
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Text(request.permission.name).font(.headline)
                    Text(request.required ? "plugin.consent.required" : "plugin.consent.optional")
                        .font(.caption2)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(request.required ? Color.orange.opacity(0.18) : Color.secondary.opacity(0.14))
                        .clipShape(Capsule())
                }
                Text(request.permission.description)
                    .font(.callout)
                Text(L10n.format("plugin.consent.reason", request.reason))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            .padding(12)
            .background(Color.secondary.opacity(0.08))
            .clipShape(RoundedRectangle(cornerRadius: 8))

            Text("plugin.consent.note")
                .font(.footnote)
                .foregroundStyle(.secondary)

            Spacer()

            HStack {
                Spacer()
                Button("plugin.consent.deny") { onResolve(false) }
                    .keyboardShortcut(.cancelAction)
                Button("plugin.consent.allow") { onResolve(true) }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 480, height: 340)
    }
}
