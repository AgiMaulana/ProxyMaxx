import SwiftUI
import AppKit
import Branding
import FlowKit
import RuleKit
import UniformTypeIdentifiers

/// Rules are evaluated in this table's order; imported bundles only own their members.
struct MapLocalView: View {
    @ObservedObject var rules: RuleStore
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []
    @State private var editing: EditorTarget?
    @State private var showEnabledOnly = false
    @State private var filterText = ""
    @State private var importPreview: MapLocalImportPreview?
    @State private var previewDirectory: URL?
    @State private var isInspecting = false
    @State private var errorMessage: String?
    @State private var bundleToRemove: MapLocalBundle?

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let rule: MapLocalRule
        let isNew: Bool
    }

    private struct RuleRow: Identifiable {
        let rule: MapLocalRule
        let order: Int
        var id: UUID { rule.id }
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            filterBar
            ruleTable
            Divider()
            footer
        }
        .frame(minWidth: 880, idealWidth: 1_100, maxWidth: 1_100,
               minHeight: 580, idealHeight: 660, maxHeight: 660)
        .sheet(item: $editing) { target in
            MapLocalEditorView(rule: target.rule, isNew: target.isNew) { savedRule in
                var saved = savedRule
                if saved.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    saved.name = MapLocalRuleNaming.untitled(existingNames: rules.mapLocalRules.map(\.name))
                }
                if target.isNew {
                    rules.addMapLocalRule(saved)
                } else {
                    rules.updateMapLocalRule(saved)
                }
                selection = [saved.id]
                onApply()
            }
        }
        .sheet(item: $importPreview, onDismiss: discardPreview) { preview in
            MapLocalBundleImportView(preview: preview) { activate in
                let bundle = try rules.importMapLocalBundle(from: preview.archiveURL, activate: activate)
                filterText = ""
                showEnabledOnly = false
                selection = Set(bundle.ruleIDs)
                onApply()
            }
        }
        .alert("mapLocal.bundle.errorTitle", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
        .confirmationDialog("mapLocal.bundle.removeTitle", isPresented: Binding(
            get: { bundleToRemove != nil },
            set: { if !$0 { bundleToRemove = nil } }
        ), titleVisibility: .visible) {
            Button("mapLocal.bundle.remove", role: .destructive) {
                guard let bundle = bundleToRemove else { return }
                perform {
                    try rules.removeMapLocalBundle(id: bundle.id)
                    onApply()
                }
                bundleToRemove = nil
            }
            Button("common.cancel", role: .cancel) { bundleToRemove = nil }
        } message: {
            Text(L10n.format("mapLocal.bundle.removeMessage", bundleToRemove?.displayName ?? ""))
        }
        .onChange(of: visibleRows.map(\.id)) { _, ids in
            selection.formIntersection(ids)
        }
    }

    private var topBar: some View {
        HStack(spacing: 12) {
            Text("common.mapLocal").font(.title2).bold()
            Toggle("mapLocal.enabled", isOn: Binding(
                get: { rules.isMapLocalEnabled },
                set: { rules.isMapLocalEnabled = $0; onApply() }
            ))
            .toggleStyle(.switch)
            .help("mapLocal.enable")

            Spacer()

            Button("mapLocal.bundle.importZIP", action: chooseImport)
                .keyboardShortcut("i", modifiers: [.command, .shift])
            Menu("mapLocal.bundle.export") {
                Button("mapLocal.bundle.exportSelected") { exportRules(ids: selection) }
                    .disabled(selection.isEmpty)
                Button("mapLocal.bundle.exportAll") { exportRules(ids: nil) }
                    .disabled(rules.mapLocalRules.isEmpty)
            }
            bundlesMenu
            Button("common.done") { onApply(); dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.cancelAction)
        }
        .disabled(isInspecting)
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var bundlesMenu: some View {
        Menu("mapLocal.bundle.bundles") {
            if rules.mapLocalBundles.isEmpty {
                Text("mapLocal.bundle.none")
            }
            ForEach(rules.mapLocalBundles) { bundle in
                Menu(bundle.displayName) {
                    let members = bundleRules(bundle)
                    Text(bundleStatus(bundle, members: members))
                    Divider()
                    Button("mapLocal.activate") {
                        perform { try rules.activateMapLocalBundle(id: bundle.id); onApply() }
                    }
                    .disabled(members.isEmpty)
                    .help("mapLocal.bundle.activateHelp")
                    Button("mapLocal.bundle.deactivate") {
                        perform { try rules.deactivateMapLocalBundle(id: bundle.id); onApply() }
                    }
                    .disabled(!members.contains(where: \.isEnabled))
                    Button("mapLocal.bundle.exportZIP") { exportBundle(bundle) }
                        .disabled(members.isEmpty)
                    Divider()
                    Button("mapLocal.bundle.remove", role: .destructive) { bundleToRemove = bundle }
                }
            }
        }
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("mapLocal.filterPlaceholder", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)
                .accessibilityLabel(Text("mapLocal.filterPlaceholder"))
            Toggle("mapLocal.showEnabled", isOn: $showEnabledOnly)
                .toggleStyle(.checkbox)
            Spacer()
            if isInspecting {
                ProgressView().controlSize(.small)
                Text("mapLocal.bundle.validating").font(.caption)
            } else {
                Text(ruleCountLabel(visibleRows.count))
                    .font(.caption)
                    .monospacedDigit()
            }
        }
        .disabled(isInspecting)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var ruleTable: some View {
        Table(visibleRows, selection: $selection) {
            TableColumn("mapLocal.order") { row in
                Text(verbatim: "\(row.order)")
                    .monospacedDigit()
                    .foregroundStyle(row.rule.isEnabled ? .primary : .secondary)
            }
            .width(38)
            TableColumn("common.name") { row in
                let rule = row.rule
                Text(rule.displayName)
                    .lineLimit(1)
                    .help(rule.displayName)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            }
            .width(min: 100, ideal: 140, max: 200)
            TableColumn("common.method") { row in
                let rule = row.rule
                Text(rule.method.displayName)
                    .font(.system(.caption, design: .monospaced))
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            }
            .width(65)
            TableColumn("mapLocal.matchStyleColumn") { row in
                let rule = row.rule
                Text(rule.matchStyle.displayName)
                    .lineLimit(1)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            }
            .width(110)
            TableColumn("mapLocal.matchingURLs") { row in
                let rule = row.rule
                Text(rule.url)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.url)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            }
            .width(min: 150, ideal: 230)
            TableColumn("mapLocal.mapFrom") { row in
                let rule = row.rule
                Label(rule.destination.path.isEmpty ? L10n.string("mapLocal.notSet") : rule.destination.path,
                      systemImage: rule.destination.symbolName)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(rule.destination.path)
                    .foregroundStyle(rule.isEnabled ? .primary : .secondary)
            }
            .width(min: 160, ideal: 220)
        }
        .contextMenu(forSelectionType: UUID.self) { ids in
            Button("common.edit") { editSelection(ids) }.disabled(ids.count != 1)
            Button("common.duplicate") { duplicate(ids) }.disabled(ids.isEmpty)
            Button("mapLocal.enableRule") { setEnabled(ids, enabled: true) }.disabled(ids.isEmpty)
            Button("mapLocal.disableRule") { setEnabled(ids, enabled: false) }.disabled(ids.isEmpty)
            Divider()
            Button("mapLocal.bundle.exportSelected") { exportRules(ids: ids) }.disabled(ids.isEmpty)
            Button("mapLocal.showInFinder") {
                if let rule = rules.mapLocalRules.first(where: { ids.contains($0.id) }) { reveal(rule) }
            }
            .disabled(ids.count != 1)
            Divider()
            Button("common.delete", role: .destructive) { delete(ids) }.disabled(ids.isEmpty)
        } primaryAction: { ids in
            editSelection(ids)
        }
        .onDeleteCommand { delete(selection) }
        .overlay {
            if visibleRows.isEmpty { emptyState }
        }
        .disabled(isInspecting)
    }

    private var emptyState: some View {
        VStack(spacing: 12) {
            Text(emptyMessage).multilineTextAlignment(.center)
            if rules.mapLocalRules.isEmpty {
                HStack {
                    Button("mapLocal.newRule", action: newRule)
                    Button("mapLocal.bundle.importZIP", action: chooseImport)
                }
            } else {
                Button("mapLocal.clearFilters") { filterText = ""; showEnabledOnly = false }
            }
        }
        .padding(24)
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button(action: newRule) { Label("mapLocal.newRule", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)
            Button { editSelection(selection) } label: { Label("common.edit", systemImage: "pencil") }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selection.count != 1)
            Button { duplicate(selection) } label: { Label("common.duplicate", systemImage: "plus.square.on.square") }
                .keyboardShortcut("d", modifiers: .command)
                .disabled(selection.isEmpty)
            Button { delete(selection) } label: { Label("common.delete", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection.isEmpty)
            Menu("mapLocal.selectedRules") {
                Button("mapLocal.enableRule") { setEnabled(selection, enabled: true) }
                Button("mapLocal.disableRule") { setEnabled(selection, enabled: false) }
            }
            .disabled(selection.isEmpty)
            Divider().frame(height: 18)
            Button { move(-1) } label: { Image(systemName: "arrow.up") }
                .keyboardShortcut(.upArrow, modifiers: [.command, .option])
                .disabled(!canMove(-1))
                .help("mapLocal.moveUpHelp")
                .accessibilityLabel(Text("mapLocal.moveUp"))
            Button { move(1) } label: { Image(systemName: "arrow.down") }
                .keyboardShortcut(.downArrow, modifiers: [.command, .option])
                .disabled(!canMove(1))
                .help("mapLocal.moveDownHelp")
                .accessibilityLabel(Text("mapLocal.moveDown"))
            Spacer()
            Text("mapLocal.orderHint").font(.caption)
        }
        .disabled(isInspecting)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var visibleRows: [RuleRow] {
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        return rules.mapLocalRules.enumerated().compactMap { index, rule in
            guard (!showEnabledOnly || rule.isEnabled) && (query.isEmpty
                || rule.name.localizedCaseInsensitiveContains(query)
                || rule.url.localizedCaseInsensitiveContains(query)
                || rule.method.displayName.localizedCaseInsensitiveContains(query)
                || rule.matchStyle.displayName.localizedCaseInsensitiveContains(query)
                || rule.destination.path.localizedCaseInsensitiveContains(query)) else { return nil }
            return RuleRow(rule: rule, order: index + 1)
        }
    }

    private var emptyMessage: String {
        if rules.mapLocalRules.isEmpty { return L10n.string("mapLocal.emptyHint") }
        let query = filterText.trimmingCharacters(in: .whitespacesAndNewlines)
        if !query.isEmpty { return L10n.format("mapLocal.noMatches", query) }
        return L10n.string("mapLocal.noEnabledRules")
    }

    private func ruleCountLabel(_ count: Int) -> String {
        count == 1 ? L10n.string("mapLocal.ruleCountOne") : L10n.format("mapLocal.ruleCount", count)
    }

    private func bundleRules(_ bundle: MapLocalBundle) -> [MapLocalRule] {
        let ids = Set(bundle.ruleIDs)
        return rules.mapLocalRules.filter { ids.contains($0.id) }
    }

    private func bundleStatus(_ bundle: MapLocalBundle, members: [MapLocalRule]) -> String {
        if rules.isMapLocalBundleActive(bundle) { return L10n.string("mapLocal.bundle.active") }
        if members.isEmpty { return L10n.string("mapLocal.bundle.empty") }
        let enabled = members.filter(\.isEnabled).count
        if enabled == 0 { return L10n.string("mapLocal.bundle.inactive") }
        return L10n.format("mapLocal.bundle.modified", enabled, members.count)
    }

    private func perform(_ action: () throws -> Void) {
        do { try action() } catch { errorMessage = error.localizedDescription }
    }

    private func chooseImport() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.zip]
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.title = L10n.string("mapLocal.bundle.importZIP")
        guard panel.runModal() == .OK, let url = panel.url else { return }
        isInspecting = true
        Task { @MainActor in
            do {
                let preview = try await Task.detached(priority: .userInitiated) {
                    let directory = FileManager.default.temporaryDirectory
                        .appendingPathComponent(UUID().uuidString, isDirectory: true)
                    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
                    do {
                        let staged = directory.appendingPathComponent("bundle.zip")
                        try FileManager.default.copyItem(at: url, to: staged)
                        let manifest = try MapLocalBundleArchive.inspect(staged)
                        return MapLocalImportPreview(archiveURL: staged, manifest: manifest)
                    } catch {
                        try? FileManager.default.removeItem(at: directory)
                        throw error
                    }
                }.value
                previewDirectory = preview.archiveURL.deletingLastPathComponent()
                importPreview = preview
            } catch {
                errorMessage = error.localizedDescription
            }
            isInspecting = false
        }
    }

    private func discardPreview() {
        if let previewDirectory { try? FileManager.default.removeItem(at: previewDirectory) }
        previewDirectory = nil
        importPreview = nil
    }

    private func exportRules(ids: Set<UUID>?) {
        saveZIP(suggestedName: "Local Overrides") { url, name in
            try rules.exportMapLocalRules(ids: ids, name: name, to: url)
        }
    }

    private func exportBundle(_ bundle: MapLocalBundle) {
        saveZIP(suggestedName: bundle.displayName) { url, _ in
            try rules.exportMapLocalBundle(id: bundle.id, to: url)
        }
    }

    private func saveZIP(suggestedName: String, export: (URL, String) throws -> Void) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.zip]
        panel.canCreateDirectories = true
        panel.nameFieldStringValue = suggestedName.replacingOccurrences(of: "/", with: "-") + ".zip"
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        perform {
            let directory = destination.deletingLastPathComponent()
                .appendingPathComponent(".proxymaxx-export-" + UUID().uuidString, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
            defer { try? FileManager.default.removeItem(at: directory) }
            let staged = directory.appendingPathComponent("bundle.zip")
            let name = destination.deletingPathExtension().lastPathComponent
            try export(staged, name)
            if FileManager.default.fileExists(atPath: destination.path) {
                _ = try FileManager.default.replaceItemAt(destination, withItemAt: staged)
            } else {
                try FileManager.default.moveItem(at: staged, to: destination)
            }
        }
    }

    private func newRule() {
        editing = EditorTarget(rule: MapLocalRule(name: "", url: "*", matchStyle: .wildcard,
            includePath: true, destination: .file("")), isNew: true)
    }

    private func editSelection(_ ids: Set<UUID>) {
        guard ids.count == 1, let rule = rules.mapLocalRules.first(where: { ids.contains($0.id) }) else { return }
        editing = EditorTarget(rule: rule, isNew: false)
    }

    private func duplicate(_ ids: Set<UUID>) {
        let originals = rules.mapLocalRules.filter { ids.contains($0.id) }.map(\.id)
        for id in originals { rules.duplicateMapLocalRule(id: id) }
        if !originals.isEmpty { onApply() }
    }

    private func delete(_ ids: Set<UUID>) {
        guard !ids.isEmpty else { return }
        rules.removeMapLocalRules(ids: ids)
        selection.subtract(ids)
        onApply()
    }

    private func setEnabled(_ ids: Set<UUID>, enabled: Bool) {
        for id in ids { rules.setMapLocalRule(id: id, enabled: enabled) }
        if !ids.isEmpty { onApply() }
    }

    private func canMove(_ offset: Int) -> Bool {
        rules.mapLocalRules.indices.contains { index in
            let neighbor = index + offset
            return selection.contains(rules.mapLocalRules[index].id)
                && rules.mapLocalRules.indices.contains(neighbor)
                && !selection.contains(rules.mapLocalRules[neighbor].id)
        }
    }

    private func move(_ offset: Int) {
        let ordered = rules.mapLocalRules.filter { selection.contains($0.id) }.map(\.id)
        for step in ordered.indices {
            let id = ordered[offset < 0 ? step : ordered.count - 1 - step]
            guard let index = rules.mapLocalRules.firstIndex(where: { $0.id == id }) else { continue }
            let neighbor = index + offset
            if rules.mapLocalRules.indices.contains(neighbor), !selection.contains(rules.mapLocalRules[neighbor].id) {
                rules.moveMapLocalRule(id: id, by: offset)
            }
        }
        onApply()
    }

    private func reveal(_ rule: MapLocalRule) {
        guard !rule.destination.path.isEmpty else { return }
        let url = URL(fileURLWithPath: (rule.destination.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }

    public static func generateDefaultFile() -> String {
        let directory = Brand.supportDirectory.appendingPathComponent("map-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory.appendingPathComponent("default_message_\(UUID().uuidString.prefix(8)).json").path
    }
}

// MARK: - Editor

struct MapLocalEditorView: View {
    init(
        rule: MapLocalRule,
        isNew: Bool,
        onSave: @escaping (MapLocalRule) -> Void
    ) {
        self.isNew = isNew
        self.onSave = onSave
        _draft = State(initialValue: rule)
        let initialPath = rule.destination.path.isEmpty ? MapLocalView.generateDefaultFile() : rule.destination.path
        _path = State(initialValue: initialPath)
        _isDirectory = State(initialValue: !rule.destination.isFile)

        let expanded = (initialPath as NSString).expandingTildeInPath
        let loaded = rule.destination.isFile ? (try? String(contentsOfFile: expanded, encoding: .utf8)) : nil
        let exists = FileManager.default.fileExists(atPath: expanded)
        _loadedResponse = State(initialValue: loaded)
        _canEditResponse = State(initialValue: loaded != nil || !exists)
        _responseContent = State(initialValue: loaded ?? (exists ? "" : Self.responseTemplate))
    }

    private static let responseTemplate = """
    HTTP/1.1 200 OK
    Content-Type: application/json; charset=utf-8

    {
      "message": "success",
      "data": {}
    }
    """

    private let isNew: Bool
    private let onSave: (MapLocalRule) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MapLocalRule
    @State private var path: String
    @State private var isDirectory: Bool
    @State private var responseContent: String
    @State private var loadedResponse: String?
    @State private var canEditResponse: Bool
    @State private var errorMessage: String?

    private static let methods = ["", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                matchingRuleCard
                responseCard
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 880, height: 700)
        .alert("mapLocal.saveErrorTitle", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isNew ? L10n.string("mapLocal.createTitle") : L10n.string("mapLocal.editTitle"))
                .font(.title3).bold()
            Text("mapLocal.formSubtitle")
                .font(.caption)
                .foregroundStyle(.primary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var matchingRuleCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("mapLocal.matchingRule")
                .font(.headline)

            formRow("mapLocal.nameLabel") {
                TextField("mapLocal.untitledRule", text: $draft.name)
                    .textFieldStyle(.roundedBorder)
            }

            formRow("mapLocal.urlLabel") {
                TextField("mapLocal.urlPlaceholder", text: $draft.url)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
            }

            formRow("mapLocal.matchStyleLabel") {
                HStack(spacing: 12) {
                    Picker("", selection: $draft.matchStyle) {
                        ForEach(URLMatchStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Toggle("mapLocal.includeSubpathsShort", isOn: $draft.includePath)
                        .toggleStyle(.checkbox)
                }
            }

            formRow("mapLocal.methodLabel") {
                HStack(spacing: 12) {
                    Picker("", selection: methodBinding) {
                        Text("common.any").tag("")
                        ForEach(Self.methods.dropFirst(), id: \.self) { Text($0).tag($0) }
                        if !draft.method.isAny, !Self.methods.contains(draft.method.displayName) {
                            Text(draft.method.displayName).tag(draft.method.displayName)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Text("mapLocal.delayLabel")
                        .foregroundStyle(.primary)

                    Picker("", selection: delayBinding) {
                        ForEach(MapLocalDelay.allCases) { Text($0.displayName).tag($0.rawValue) }
                        if !MapLocalDelay.allCases.contains(where: { $0.rawValue == draft.responseDelay }) {
                            Text(L10n.format("mapLocal.customDelay", draft.responseDelay)).tag(draft.responseDelay)
                        }
                    }
                    .labelsHidden()
                    .frame(width: 150)
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }


    private var responseCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("mapLocal.mapTo")
                    .font(.headline)
                Spacer()
                Picker("", selection: $isDirectory) {
                    Text("mapLocal.localFile").tag(false)
                    Text("mapLocal.localDirectory").tag(true)
                }
                .pickerStyle(.segmented)
                .frame(width: 200)
            }

            formRow(isDirectory ? "mapLocal.directoryLabel" : "mapLocal.filePathLabel") {
                HStack(spacing: 8) {
                    TextField(
                        isDirectory ? L10n.string("mapLocal.chooseDirectory") : L10n.string("mapLocal.filePathPlaceholder"),
                        text: $path
                    )
                    .textFieldStyle(.roundedBorder)
                    .font(.system(.body, design: .monospaced))
                    Button("mapLocal.select") { select() }
                    Button("mapLocal.finder") { reveal() }.disabled(path.isEmpty)
                }
            }

            HStack {
                Color.clear.frame(width: Self.labelColumnWidth + 12, height: 1)
                statusLine
            }

            if !isDirectory {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("mapLocal.responseContentLabel")
                            .font(.caption)
                            .foregroundStyle(.primary)
                        Spacer()
                        Button("mapLocal.insertTemplate") {
                            canEditResponse = true
                            responseContent = Self.responseTemplate
                        }
                        .font(.caption)
                    }

                    TextEditor(text: $responseContent)
                        .disabled(!canEditResponse)
                        .font(.system(.body, design: .monospaced))
                        .frame(minHeight: 110, maxHeight: .infinity)
                        .scrollContentBackground(.hidden)
                        .padding(8)
                        .background(Color(NSColor.textBackgroundColor))
                        .cornerRadius(6)
                        .overlay(
                            RoundedRectangle(cornerRadius: 6)
                                .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                        )

                    if !canEditResponse {
                        Text("mapLocal.binaryResponseHint").font(.caption)
                    }
                    Text("mapLocal.fileHint")
                        .font(.caption)
                        .foregroundStyle(.primary)
                }
                .frame(maxHeight: .infinity)
            } else {
                Text("mapLocal.directoryHint")
                    .font(.caption)
                    .foregroundStyle(.primary)
                Spacer()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }

    private var footer: some View {
        HStack {
            Spacer()
            Button("common.cancel") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(isNew ? L10n.string("mapLocal.addRule") : L10n.string("mapLocal.saveChanges")) { save() }
                .keyboardShortcut(.defaultAction)
                .disabled(draft.url.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .padding(16)
    }


    private func formRow<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: Self.labelColumnWidth, alignment: .trailing)
                .foregroundStyle(.primary)
            content()
        }
    }

    private static let labelColumnWidth: CGFloat = 90

    // MARK: - Field bindings

    private var methodBinding: Binding<String> {
        Binding(
            get: { draft.method.isAny ? "" : draft.method.displayName },
            set: { draft.method = MethodMatch($0) }
        )
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { draft.responseDelay },
            set: { draft.responseDelay = $0 }
        )
    }

    @ViewBuilder
    private var statusLine: some View {
        if path.isEmpty {
            Text(isDirectory
                 ? L10n.string("mapLocal.pickDirectoryHelp")
                 : L10n.string("mapLocal.pickFileHelp"))
                .font(.caption).foregroundStyle(.primary)
        } else if !FileManager.default.fileExists(atPath: expandedPath) {
            Label(isDirectory ? L10n.string("mapLocal.directoryMissing") : L10n.string("mapLocal.fileMissing"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.primary)
        } else if !isDirectory, isLargeFile {
            Label(L10n.string("mapLocal.fileTooLarge"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.primary)
        } else {
            Label(isDirectory ? L10n.string("mapLocal.directoryFound") : L10n.string("mapLocal.fileFound"), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.primary)
        }
    }

    private var expandedPath: String {
        (path as NSString).expandingTildeInPath
    }

    private var isLargeFile: Bool {
        let attributes = try? FileManager.default.attributesOfItem(atPath: expandedPath)
        let size = (attributes?[.size] as? NSNumber)?.intValue ?? 0
        return size > 20 * 1024 * 1024
    }

    // MARK: - Actions

    private func select() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = isDirectory
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
            if !isDirectory {
                loadedResponse = try? String(contentsOf: url, encoding: .utf8)
                canEditResponse = loadedResponse != nil
                responseContent = loadedResponse ?? ""
            }
        }
    }

    private func reveal() {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandedPath)])
    }

    private func save() {
        draft.url = draft.url.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedPath = path.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !draft.url.isEmpty, !trimmedPath.isEmpty else {
            errorMessage = L10n.string("mapLocal.requiredFields")
            return
        }
        if draft.matchStyle == .regex {
            do { _ = try NSRegularExpression(pattern: draft.url) }
            catch { errorMessage = error.localizedDescription; return }
        }
        let destination = URL(fileURLWithPath: (trimmedPath as NSString).expandingTildeInPath)
        do {
            if !isDirectory {
                var isFolder: ObjCBool = false
                if FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder), isFolder.boolValue {
                    errorMessage = L10n.string("mapLocal.expectedFile")
                    return
                }
                if canEditResponse, responseContent != loadedResponse {
                    try FileManager.default.createDirectory(at: destination.deletingLastPathComponent(),
                                                            withIntermediateDirectories: true)
                    try responseContent.write(to: destination, atomically: true, encoding: .utf8)
                } else if !FileManager.default.fileExists(atPath: destination.path) {
                    errorMessage = L10n.string("mapLocal.fileMissing")
                    return
                }
            } else {
                var isFolder: ObjCBool = false
                guard FileManager.default.fileExists(atPath: destination.path, isDirectory: &isFolder),
                      isFolder.boolValue else {
                    errorMessage = L10n.string("mapLocal.directoryMissing")
                    return
                }
            }
            draft.destination = isDirectory ? .directory(destination.path) : .file(destination.path)
            onSave(draft)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

