import SwiftUI
import AppKit
import Branding
import FlowKit
import RuleKit

/// Map Local: answer matched requests from a local file or directory instead of the network.
///
/// The layout follows the rest of the app: an enable switch, the rule list in the order
/// rules are evaluated, the actions that operate on the selection, and a shortcut summary.
struct MapLocalView: View {
    @ObservedObject var rules: RuleStore
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var editing: EditorTarget?
    @State private var showEnabledOnly = false
    @State private var isNamingScenario = false
    @State private var scenarioName = ""

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let rule: MapLocalRule
        let isNew: Bool
    }
    private var visibleRules: [MapLocalRule] {
        showEnabledOnly ? rules.mapLocalRules.filter(\.isEnabled) : rules.mapLocalRules
    }

    private var selectedRule: MapLocalRule? {
        rules.mapLocalRules.first { $0.id == selection }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            Toggle("mapLocal.enable", isOn: Binding(
                get: { rules.isMapLocalEnabled },
                set: { rules.isMapLocalEnabled = $0; onApply() }
            ))
            .toggleStyle(.switch)
            .padding(.horizontal, 16)
            .padding(.top, 10)

            Text("mapLocal.intro")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            Text("mapLocal.orderHint")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 16)
                .padding(.top, 2)
                .padding(.bottom, 10)

            Divider()
            columnHeader
            Divider()
            ruleList
            Divider()
            footer
        }
        .frame(width: 880, height: 580)
        .alert("mapLocal.scenarioNameTitle", isPresented: $isNamingScenario) {
            TextField("mapLocal.scenarioNamePlaceholder", text: $scenarioName)
            Button("common.cancel", role: .cancel) { scenarioName = "" }
            Button("common.save") { captureScenario() }
                .disabled(scenarioName.trimmingCharacters(in: .whitespaces).isEmpty)
        } message: {
            Text("mapLocal.scenarioHelp")
        }
        .sheet(item: $editing) { target in
            MapLocalEditorView(
                rule: target.rule,
                isNew: target.isNew,
                scenarios: rules.mapLocalScenarios
            ) { saved, scenarioID, newScenarioName in
                if target.isNew {
                    rules.addMapLocalRule(saved)
                } else {
                    rules.updateMapLocalRule(saved)
                }
                // The dropdown picks one home for the rule. A new name creates that
                // scenario first, then the rule moves into it like any other choice.
                if let scenarioID {
                    rules.setMapLocalScenarios([scenarioID], forRule: saved.id)
                } else if let scenario = rules.addRuleToScenario(saved.id, named: newScenarioName) {
                    rules.setMapLocalScenarios([scenario.id], forRule: saved.id)
                } else {
                    rules.setMapLocalScenarios([], forRule: saved.id)
                }
                selection = saved.id
                onApply()
            }
        }
    }

    private var header: some View {
        HStack {
            Text("common.mapLocal").font(.title2).bold()
            Spacer()
            Button("common.done") { onApply(); dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            Color.clear.frame(width: Self.enableColumnWidth)
            Text("common.name").frame(width: Self.nameColumnWidth, alignment: .leading)
            Text("common.method").frame(width: Self.methodColumnWidth, alignment: .leading)
            Text("mapLocal.matchingRule").frame(width: Self.ruleColumnWidth, alignment: .leading)
                .help("mapLocal.matchingURLs")
            Text("mapLocal.mapFrom").frame(maxWidth: .infinity, alignment: .leading)
                .help("mapLocal.mapBody")
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    @ViewBuilder
    private var ruleList: some View {
        if visibleRules.isEmpty {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus").font(.system(size: 30)).foregroundStyle(.tertiary)
                Text(rules.mapLocalRules.isEmpty
                     ? L10n.string("mapLocal.emptyHint")
                     : L10n.string("mapLocal.noEnabledRules"))
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            List(selection: $selection) {
                ForEach(visibleRules) { rule in
                    row(rule)
                        .tag(rule.id)
                        .contextMenu { contextMenu(for: rule) }
                }
                .onMove(perform: showEnabledOnly ? nil : handleMove)
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func row(_ rule: MapLocalRule) -> some View {
        HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { rules.setMapLocalRule(id: rule.id, enabled: $0); onApply() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.enableColumnWidth)

            Text(rule.name.isEmpty ? L10n.string("common.untitled") : rule.name)
                .lineLimit(1)
                .foregroundStyle(rule.isEnabled ? .primary : .secondary)
                .frame(width: Self.nameColumnWidth, alignment: .leading)

            Text(rule.method.displayName)
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: Self.methodColumnWidth, alignment: .leading)

            Text(rule.url.isEmpty ? L10n.string("mapLocal.anyURL") : rule.url)
                .font(.system(.caption, design: .monospaced))
                .lineLimit(1)
                .truncationMode(.middle)
                .help(Text(verbatim: L10n.format("inspector.metric", rule.matchStyle.displayName, rule.url)))
                .frame(width: Self.ruleColumnWidth, alignment: .leading)

            HStack(spacing: 6) {
                Image(systemName: rule.destination.symbolName).foregroundStyle(.secondary)
                Text(rule.destination.path.isEmpty ? L10n.string("mapLocal.notSet") : rule.destination.path)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .foregroundStyle(rule.destination.path.isEmpty ? .tertiary : .secondary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 2)
        .opacity(rule.isEnabled ? 1 : 0.55)
    }

    @ViewBuilder
    private func contextMenu(for rule: MapLocalRule) -> some View {
        Button("common.edit") { edit(rule) }
        Button("common.duplicate") { rules.duplicateMapLocalRule(id: rule.id); onApply() }
        Button(rule.isEnabled ? L10n.string("mapLocal.disableRule") : L10n.string("mapLocal.enableRule")) {
            rules.setMapLocalRule(id: rule.id, enabled: !rule.isEnabled); onApply()
        }
        Divider()
        Button("mapLocal.showInFinder") { reveal(rule) }.disabled(rule.destination.path.isEmpty)
        Divider()
        Button("common.delete") { delete([rule.id]) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { newRule() } label: { Label("mapLocal.newRule", systemImage: "plus") }
                .keyboardShortcut("n", modifiers: .command)

            Button { if let selectedRule { edit(selectedRule) } } label: { Label("common.edit", systemImage: "pencil") }
                .keyboardShortcut(.return, modifiers: .command)
                .disabled(selectedRule == nil)

            Button { if let selectedRule { rules.duplicateMapLocalRule(id: selectedRule.id); onApply() } } label: {
                Label("common.duplicate", systemImage: "plus.square.on.square")
            }
            .keyboardShortcut("d", modifiers: .command)
            .disabled(selectedRule == nil)

            Button { if let selection { delete([selection]) } } label: { Label("common.delete", systemImage: "trash") }
                .keyboardShortcut(.delete, modifiers: .command)
                .disabled(selection == nil)

            Button { if let selection { rules.setMapLocalRule(id: selection, enabled: !(selectedRule?.isEnabled ?? true)); onApply() } } label: {
                Label("mapLocal.enableRule", systemImage: "checkmark.circle")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(selectedRule == nil)

            Divider().frame(height: 18)

            Button { move(-1) } label: { Image(systemName: "arrow.up") }
                .disabled(!canMove(-1))
                .help("mapLocal.moveUpHelp")
            Button { move(1) } label: { Image(systemName: "arrow.down") }
                .disabled(!canMove(1))

            scenarioMenu

            Spacer()

            Toggle("mapLocal.showEnabled", isOn: $showEnabledOnly)
                .toggleStyle(.checkbox)
                .help("mapLocal.showEnabledHelp")

            Text("mapLocal.shortcuts")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    /// Scenarios behave like saved switchboards: pick one and the rule list matches it.
    private var scenarioMenu: some View {
        Menu {
            if rules.mapLocalScenarios.isEmpty {
                Text("mapLocal.noScenarios")
            } else {
                ForEach(rules.mapLocalScenarios) { scenario in
                    Button {
                        rules.activateMapLocalScenario(id: scenario.id)
                        onApply()
                    } label: {
                        if rules.isMapLocalScenarioActive(scenario) {
                            Label(scenario.displayName, systemImage: "checkmark")
                        } else {
                            Text(scenario.displayName)
                        }
                    }
                }
                Divider()
                Menu("mapLocal.deleteScenario") {
                    ForEach(rules.mapLocalScenarios) { scenario in
                        Button(scenario.displayName) {
                            rules.removeMapLocalScenario(id: scenario.id)
                            onApply()
                        }
                    }
                }
                Divider()
            }
            Button("mapLocal.captureScenario") {
                scenarioName = ""
                isNamingScenario = true
            }
            .disabled(!rules.mapLocalRules.contains { $0.isEnabled })
        } label: {
            Label("mapLocal.scenarios", systemImage: "square.stack.3d.up")
        }
        .fixedSize()
        .help("mapLocal.scenarioHelp")
    }

    // MARK: - Actions

    private func captureScenario() {
        let enabled = rules.mapLocalRules.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { return }
        rules.saveMapLocalScenario(MapLocalScenario(name: scenarioName, ruleIDs: enabled))
        scenarioName = ""
        onApply()
    }

    private static let enableColumnWidth: CGFloat = 20
    private static let nameColumnWidth: CGFloat = 150
    private static let methodColumnWidth: CGFloat = 72
    private static let ruleColumnWidth: CGFloat = 240

    public static var defaultMapLocalDirectory: URL {
        let dir = Brand.supportDirectory
            .appendingPathComponent("map-local", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    public static func generateDefaultFile() -> String {
        let dir = defaultMapLocalDirectory
        let uuidHex = String(UUID().uuidString.prefix(8))
        let fileName = "default_message_\(uuidHex).json"
        let fileURL = dir.appendingPathComponent(fileName)
        
        let defaultContent = """
        HTTP/1.1 200 OK
        Content-Type: application/json; charset=utf-8

        {
          "message": "success",
          "meta": { "status_code": 200, "page": 1, "size": 1, "total_count": 1 },
          "data": [
            { "prescription_id": 1, "consult_id": 2697781, "item_count": 2 }
          ]
        }
        """
        try? defaultContent.write(to: fileURL, atomically: true, encoding: .utf8)
        return fileURL.path
    }

    private func newRule() {
        let path = MapLocalView.generateDefaultFile()
        let rule = MapLocalRule(name: "", url: "*", matchStyle: .wildcard, includePath: true, destination: .file(path))
        editing = EditorTarget(rule: rule, isNew: true)
    }

    private func edit(_ rule: MapLocalRule) {
        editing = EditorTarget(rule: rule, isNew: false)
    }

    private func delete(_ ids: Set<UUID>) {
        rules.removeMapLocalRules(ids: ids)
        if let selection, ids.contains(selection) { self.selection = nil }
        onApply()
    }

    private func canMove(_ offset: Int) -> Bool {
        guard let selection, let index = rules.mapLocalRules.firstIndex(where: { $0.id == selection }) else { return false }
        return rules.mapLocalRules.indices.contains(index + offset)
    }

    private func move(_ offset: Int) {
        guard let selection else { return }
        rules.moveMapLocalRule(id: selection, by: offset)
        onApply()
    }

    /// Drag-to-reorder, offered only when the list shows every rule so the drop index lines up with the store.
    private func handleMove(from offsets: IndexSet, to destination: Int) {
        rules.moveMapLocalRules(from: offsets, to: destination)
        onApply()
    }

    private func reveal(_ rule: MapLocalRule) {
        guard !rule.destination.path.isEmpty else { return }
        let url = URL(fileURLWithPath: (rule.destination.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Editor

/// The rule editor: name, matching rule, method, what to map to, and the response delay.
struct MapLocalEditorView: View {
    /// What the scenario dropdown points at. `new` reveals a name field, and the rule is
    /// put in that new scenario on save.
    private enum ScenarioChoice: Hashable {
        case none
        case existing(UUID)
        case new
    }

    init(
        rule: MapLocalRule,
        isNew: Bool,
        scenarios: [MapLocalScenario] = [],
        onSave: @escaping (MapLocalRule, UUID?, String) -> Void
    ) {
        self.isNew = isNew
        self.scenarios = scenarios
        self.onSave = onSave
        _draft = State(initialValue: rule)
        let memberships = scenarios.filter { $0.ruleIDs.contains(rule.id) }
        _scenarioChoice = State(initialValue: memberships.first.map { ScenarioChoice.existing($0.id) } ?? .none)
        let initialPath = rule.destination.path.isEmpty ? MapLocalView.generateDefaultFile() : rule.destination.path
        _path = State(initialValue: initialPath)
        _isDirectory = State(initialValue: !rule.destination.isFile)
        
        let expanded = (initialPath as NSString).expandingTildeInPath
        let content = (try? String(contentsOfFile: expanded, encoding: .utf8)) ?? """
        HTTP/1.1 200 OK
        Content-Type: application/json; charset=utf-8

        {
          "message": "success",
          "data": {}
        }
        """
        _responseContent = State(initialValue: content)
    }

    private let isNew: Bool
    private let scenarios: [MapLocalScenario]
    private let onSave: (MapLocalRule, UUID?, String) -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MapLocalRule
    @State private var path: String
    @State private var isDirectory: Bool
    @State private var responseContent: String
    @State private var scenarioChoice: ScenarioChoice
    @State private var newScenarioName = ""

    private static let methods = ["", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Header
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(isNew ? L10n.string("mapLocal.createTitle") : L10n.string("mapLocal.editTitle"))
                        .font(.title3).bold()
                    Text("mapLocal.formSubtitle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
            }
            .padding(16)

            Divider()

            VStack(alignment: .leading, spacing: 14) {
                // Matching Rule Card
                VStack(alignment: .leading, spacing: 10) {
                    Text("mapLocal.matchingRule")
                        .font(.headline)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("mapLocal.nameLabel").gridColumnAlignment(.trailing)
                            TextField("mapLocal.untitledRule", text: $draft.name)
                                .textFieldStyle(.roundedBorder)
                                .frame(width: 460)
                        }

                        GridRow {
                            Text("mapLocal.urlLabel").gridColumnAlignment(.trailing)
                            TextField("mapLocal.urlPlaceholder", text: $draft.url)
                                .textFieldStyle(.roundedBorder)
                                .font(.system(.body, design: .monospaced))
                                .frame(width: 460)
                        }

                        GridRow {
                            Text("mapLocal.matchStyleLabel").gridColumnAlignment(.trailing)
                            HStack(spacing: 12) {
                                Picker("", selection: $draft.matchStyle) {
                                    ForEach(URLMatchStyle.allCases, id: \.self) { Text($0.displayName).tag($0) }
                                }
                                .labelsHidden()
                                .frame(width: 180)

                                Toggle("mapLocal.includeSubpaths", isOn: $draft.includePath)
                                    .toggleStyle(.checkbox)
                            }
                        }

                        GridRow {
                            Text("mapLocal.methodLabel").gridColumnAlignment(.trailing)
                            Picker("", selection: methodBinding) {
                                Text("common.any").tag("")
                                ForEach(Self.methods.dropFirst(), id: \.self) { Text($0).tag($0) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }

                        GridRow {
                            Text("mapLocal.delayLabel").gridColumnAlignment(.trailing)
                            Picker("", selection: delayBinding) {
                                ForEach(MapLocalDelay.allCases) { Text($0.displayName).tag($0.rawValue) }
                            }
                            .labelsHidden()
                            .frame(width: 180)
                        }
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)

                // Map To Card (Expanding vertically)
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

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text(isDirectory ? L10n.string("mapLocal.directoryLabel") : L10n.string("mapLocal.filePathLabel")).gridColumnAlignment(.trailing)
                            HStack(spacing: 8) {
                                TextField(isDirectory ? L10n.string("mapLocal.chooseDirectory") : L10n.string("mapLocal.filePathPlaceholder"), text: $path)
                                    .textFieldStyle(.roundedBorder)
                                    .font(.system(.body, design: .monospaced))
                                    .frame(width: 360)
                                Button("mapLocal.select") { select() }
                                Button("mapLocal.finder") { reveal() }.disabled(path.isEmpty)
                            }
                        }

                        GridRow {
                            Text("").gridColumnAlignment(.trailing)
                            statusLine
                        }
                    }

                    if !isDirectory {
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text("mapLocal.responseContentLabel")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                                Spacer()
                                Button("mapLocal.insertTemplate") {
                                    responseContent = """
                                    HTTP/1.1 200 OK
                                    Content-Type: application/json; charset=utf-8

                                    {
                                      "message": "success",
                                      "data": {}
                                    }
                                    """
                                }
                                .font(.caption)
                            }

                            TextEditor(text: $responseContent)
                                .font(.system(.body, design: .monospaced))
                                .frame(minHeight: 160, maxHeight: .infinity)
                                .scrollContentBackground(.hidden)
                                .padding(8)
                                .background(Color(NSColor.textBackgroundColor))
                                .cornerRadius(6)
                                .overlay(
                                    RoundedRectangle(cornerRadius: 6)
                                        .stroke(Color(NSColor.separatorColor), lineWidth: 1)
                                )

                            Text("mapLocal.fileHint")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        .frame(maxHeight: .infinity)
                    } else {
                        Text("mapLocal.directoryHint")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
                .frame(maxHeight: .infinity)

                // Scenario membership as one dropdown: none, an existing scenario, or a
                // new one named inline. Choosing one moves the rule into it.
                VStack(alignment: .leading, spacing: 10) {
                    Text("mapLocal.scenarios")
                        .font(.headline)
                    Text("mapLocal.scenarioFormHelp")
                        .font(.caption)
                        .foregroundStyle(.secondary)

                    Grid(alignment: .leading, horizontalSpacing: 14, verticalSpacing: 8) {
                        GridRow {
                            Text("mapLocal.scenarioLabel")
                                .gridColumnAlignment(.trailing)
                            Picker("", selection: $scenarioChoice) {
                                Text("mapLocal.scenarioNone").tag(ScenarioChoice.none)
                                ForEach(scenarios) { scenario in
                                    Text(scenario.displayName).tag(ScenarioChoice.existing(scenario.id))
                                }
                                Text("mapLocal.scenarioNewOption").tag(ScenarioChoice.new)
                            }
                            .labelsHidden()
                            .frame(width: 240)
                        }

                        if scenarioChoice == .new {
                            GridRow {
                                Text("").gridColumnAlignment(.trailing)
                                HStack(spacing: 8) {
                                    TextField("mapLocal.newScenarioPlaceholder", text: $newScenarioName)
                                        .textFieldStyle(.roundedBorder)
                                        .frame(width: 240)
                                    Text("mapLocal.newScenarioHint")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }

                    if membershipCount > 1 {
                        Text(L10n.format("mapLocal.scenarioMultipleHint", membershipCount))
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
                .padding(12)
                .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
                .cornerRadius(8)
            }
            .padding(16)

            Divider()

            // Footer
            HStack {
                Spacer()
                Button("common.cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                Button(isNew ? L10n.string("mapLocal.addRule") : L10n.string("mapLocal.saveChanges")) { save() }
                    .keyboardShortcut(.defaultAction)
                    .disabled(
                        draft.url.trimmingCharacters(in: .whitespaces).isEmpty
                        || (scenarioChoice == .new && newScenarioName.trimmingCharacters(in: .whitespaces).isEmpty)
                    )
            }
            .padding(16)
        }
        .frame(minWidth: 720, idealWidth: 840, maxWidth: .infinity, minHeight: 620, idealHeight: 840, maxHeight: .infinity)
    }

    /// Scenarios currently containing the rule, so the editor can admit when the
    /// dropdown is showing only the first of several (CLI and capture can overlap them).
    private var membershipCount: Int {
        scenarios.filter { $0.ruleIDs.contains(draft.id) }.count
    }

    @ViewBuilder
    private var statusLine: some View {
        if path.isEmpty {
            Text(isDirectory
                 ? L10n.string("mapLocal.pickDirectoryHelp")
                 : L10n.string("mapLocal.pickFileHelp"))
                .font(.caption).foregroundStyle(.tertiary)
        } else if !FileManager.default.fileExists(atPath: expandedPath) {
            Label(isDirectory ? L10n.string("mapLocal.directoryMissing") : L10n.string("mapLocal.fileMissing"), systemImage: "exclamationmark.triangle.fill")
                .font(.caption).foregroundStyle(.orange)
        } else if !isDirectory, isLargeFile {
            Label(L10n.string("mapLocal.fileTooLarge"), systemImage: "exclamationmark.triangle")
                .font(.caption).foregroundStyle(.orange)
        } else {
            Label(isDirectory ? L10n.string("mapLocal.directoryFound") : L10n.string("mapLocal.fileFound"), systemImage: "checkmark.circle.fill")
                .font(.caption).foregroundStyle(.green)
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

    private var methodBinding: Binding<String> {
        Binding(
            get: { draft.method.isAny ? "" : draft.method.displayName },
            set: { draft.method = MethodMatch($0) }
        )
    }

    private var delayBinding: Binding<Double> {
        Binding(
            get: { MapLocalDelay.closest(to: draft.responseDelay)?.rawValue ?? draft.responseDelay },
            set: { draft.responseDelay = $0 }
        )
    }

    private func select() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = !isDirectory
        panel.canChooseDirectories = isDirectory
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = isDirectory
        if panel.runModal() == .OK, let url = panel.url {
            path = url.path
        }
    }

    private func reveal() {
        guard !path.isEmpty else { return }
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: expandedPath)])
    }

    private func save() {
        draft.url = draft.url.trimmingCharacters(in: .whitespaces)
        let trimmedPath = path.trimmingCharacters(in: .whitespaces)
        if !isDirectory, !trimmedPath.isEmpty {
            let expanded = (trimmedPath as NSString).expandingTildeInPath
            try? responseContent.write(toFile: expanded, atomically: true, encoding: .utf8)
        }
        draft.destination = isDirectory ? .directory(trimmedPath) : .file(trimmedPath)
        switch scenarioChoice {
        case .none:
            onSave(draft, nil, "")
        case .existing(let scenarioID):
            onSave(draft, scenarioID, "")
        case .new:
            onSave(draft, nil, newScenarioName)
        }
        dismiss()
    }
}
