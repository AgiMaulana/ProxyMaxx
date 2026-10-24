import SwiftUI
import AppKit
import Branding
import FlowKit
import RuleKit

/// Map Local: answer matched requests from a local file or directory instead of the network.
///
/// Scenarios are the left sidebar. Browsing a scenario only filters the list; activation is
/// the dot on the row or the button in the filtered header. The split matters because a
/// scenario can be inspected while a different one is running the proxy.
struct MapLocalView: View {
    @ObservedObject var rules: RuleStore
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var selection: UUID?
    @State private var editing: EditorTarget?
    @State private var showEnabledOnly = false
    @State private var filterText = ""
    @State private var filter: ScenarioFilter = .all
    @State private var isNamingScenario = false
    @State private var scenarioName = ""
    @State private var renamingScenarioID: UUID?
    @State private var renameText = ""
    @State private var hoveredScenarioID: UUID?
    @State private var namingIntent: ScenarioNamingIntent = .capture
    @State private var detailWidth: CGFloat = 900
    @State private var swapNotice: SwapNotice?
    @State private var swapNoticeTask: Task<Void, Never>?

    private enum ScenarioFilter: Hashable {
        case all
        case unassigned
        case scenario(UUID)
    }

    private enum ScenarioNamingIntent {
        case newScenario
        case capture
    }

    private struct SwapNotice: Identifiable {
        let id = UUID()
        let message: String
        let swaps: [MapLocalScenarioSwap]
    }

    private struct EndpointSection: Identifiable {
        let endpoint: MapLocalEndpoint
        let rules: [MapLocalRule]
        var id: String { endpoint.key }
    }

    private struct EditorTarget: Identifiable {
        let id = UUID()
        let rule: MapLocalRule
        let isNew: Bool
        var initialScenarioIDs: Set<UUID> = []
    }

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Divider()
            HStack(spacing: 0) {
                sidebar
                Divider()
                detailPane
            }
        }
        .frame(
            minWidth: 880,
            idealWidth: 1_100,
            maxWidth: 1_100,
            minHeight: 580,
            idealHeight: 660,
            maxHeight: 660
        )
        .alert(
            namingIntent == .newScenario
                ? L10n.string("mapLocal.newScenarioTitle")
                : L10n.string("mapLocal.scenarioNameTitle"),
            isPresented: $isNamingScenario
        ) {
            TextField("mapLocal.scenarioNamePlaceholder", text: $scenarioName)
            Button("common.cancel", role: .cancel) { scenarioName = "" }
            Button("common.save") { submitScenarioName() }
                .disabled(scenarioName.trimmingCharacters(in: .whitespaces).isEmpty
                          || (namingIntent == .newScenario && scenarioNameTaken))
        } message: {
            Text(namingIntent == .newScenario && scenarioNameTaken
                 ? L10n.string("mapLocal.scenarioNameTaken")
                 : L10n.string("mapLocal.scenarioHelp"))
        }
        .alert("mapLocal.renameScenarioTitle", isPresented: isRenamingScenario) {
            TextField("mapLocal.scenarioNamePlaceholder", text: $renameText)
            Button("common.cancel", role: .cancel) {
                renamingScenarioID = nil
                renameText = ""
            }
            Button("common.save") { commitRename() }
                .disabled(renameText.trimmingCharacters(in: .whitespaces).isEmpty || renameCollides)
        } message: {
            Text("mapLocal.renameScenarioHelp")
        }
        .sheet(item: $editing) { target in
            MapLocalEditorView(
                rule: target.rule,
                isNew: target.isNew,
                scenarios: rules.mapLocalScenarios,
                existingRules: rules.mapLocalRules,
                initialScenarioIDs: target.initialScenarioIDs
            ) { savedRule, scenarioIDs, newScenarioNames in
                var saved = savedRule
                if saved.name.trimmingCharacters(in: .whitespaces).isEmpty {
                    saved.name = MapLocalRuleNaming.untitled(existingNames: rules.mapLocalRules.map(\.name))
                }
                let activeID = rules.activeMapLocalScenarioID
                let wasMember = activeID.map { id in
                    !target.isNew && (rules.mapLocalScenarios.first { $0.id == id }?.ruleIDs.contains(target.rule.id) ?? false)
                } ?? false

                if target.isNew {
                    rules.addMapLocalRule(saved)
                } else {
                    rules.updateMapLocalRule(saved)
                }
                // Chips are the whole truth for this rule. A new name creates the scenario
                // first, then joins the same membership set as the checked chips.
                var memberships = scenarioIDs
                for name in newScenarioNames {
                    if let scenario = rules.addRuleToScenario(saved.id, named: name) {
                        memberships.insert(scenario.id)
                    }
                }
                let swaps = rules.setMapLocalScenarios(memberships, forRule: saved.id)
                // While a scenario runs, membership decides the switch: joining it turns
                // the rule on, leaving it turns the rule off, staying keeps a manual drift.
                if let activeID, target.isNew || wasMember != memberships.contains(activeID) {
                    rules.setMapLocalRule(id: saved.id, enabled: memberships.contains(activeID))
                }
                if !swaps.isEmpty {
                    presentSwapNotice(swaps, addedName: saved.displayName)
                }
                selection = saved.id
                onApply()
            }
        }
        .overlay(alignment: .bottom) {
            if let swapNotice {
                swapNoticeView(swapNotice)
                    .padding(.bottom, 58)
            }
        }
    }

    // MARK: - Chrome

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

            if let runningScenario {
                activeScenarioPill(runningScenario)
            }

            Button("common.done") { onApply(); dismiss() }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    @ViewBuilder
    private func activeScenarioPill(_ scenario: MapLocalScenario) -> some View {
        let modified = isModified(scenario)
        let title = modified
            ? L10n.format(
                "mapLocal.modifiedPill",
                scenario.displayName,
                enabledMemberCount(scenario),
                ruleCount(in: scenario)
             )
            : L10n.format("mapLocal.activePill", scenario.displayName)
        ScenarioStatusPillView(title: title, isModified: modified) {
            activate(scenario)
        }
    }

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 0) {
            choiceRow(
                L10n.string("mapLocal.allRules"),
                count: rules.mapLocalRules.count,
                value: .all
            )
            choiceRow(
                L10n.string("mapLocal.noScenarioGroup"),
                count: unassignedCount,
                value: .unassigned
            )

            HStack(spacing: 4) {
                Text("mapLocal.scenariosGroup")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    namingIntent = .newScenario
                    scenarioName = ""
                    isNamingScenario = true
                } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 10, weight: .bold))
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("mapLocal.newScenarioHelp")
                .accessibilityLabel(Text("mapLocal.newScenarioHelp"))
            }
            .padding(.horizontal, 16)
            .padding(.top, 16)
            .padding(.bottom, 6)

            ScrollView {
                LazyVStack(spacing: 2) {
                    if rules.mapLocalScenarios.isEmpty {
                        Text("mapLocal.noScenarios")
                            .font(.caption)
                            .foregroundStyle(.tertiary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 10)
                            .padding(.vertical, 4)
                    } else {
                        ForEach(rules.mapLocalScenarios) { scenario in
                            scenarioRow(scenario)
                        }
                    }
                }
                .padding(.horizontal, 6)
            }
            .frame(maxHeight: .infinity)

            Text("mapLocal.sidebarHint")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
                .padding(12)
        }
        .frame(width: 232)
        .background(Color(NSColor.controlBackgroundColor).opacity(0.35))
    }

    private var detailPane: some View {
        VStack(spacing: 0) {
            detailHeader
            if !runningConflictGroups.isEmpty {
                conflictBanner
            }
            filterBar
            columnHeader
            Divider()
            ruleList
            Divider()
            footer
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(
            GeometryReader { proxy in
                Color.clear.preference(key: DetailWidthKey.self, value: proxy.size.width)
            }
        )
        .onPreferenceChange(DetailWidthKey.self) { width in
            detailWidth = width
        }
    }

    /// Data that skipped the editor can still put two rules for one endpoint in a
    /// scenario. Activation keeps working — first match wins — but the list says so.
    private var conflictBanner: some View {
        VStack(alignment: .leading, spacing: 3) {
            ForEach(runningConflictGroups, id: \.endpoint) { group in
                Label(
                    L10n.format(
                        "mapLocal.conflictWarning",
                        runningScenario?.displayName ?? "",
                        group.count,
                        group.endpoint.label
                    ),
                    systemImage: "exclamationmark.triangle.fill"
                )
                .font(.caption)
                .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 7).fill(Color.orange.opacity(0.12)))
        .padding(.horizontal, 16)
        .padding(.bottom, 8)
    }

    @ViewBuilder
    private var detailHeader: some View {
        HStack(spacing: 10) {
            switch filter {
            case .all:
                Text("mapLocal.allRules").font(.title3).bold()
                Text(ruleCountLabel(rules.mapLocalRules.count))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .unassigned:
                Text("mapLocal.noScenarioGroup").font(.title3).bold()
                Text(ruleCountLabel(unassignedCount))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            case .scenario(let id):
                if let scenario = scenario(id: id) {
                    let running = runningScenario?.id == scenario.id
                    let modified = isModified(scenario)
                    let tint: Color = modified ? .orange : .green
                    Text(scenario.displayName)
                        .font(.title3)
                        .bold()
                        .lineLimit(1)
                    if running {
                        Text(L10n.string(modified ? "mapLocal.modifiedBadge" : "mapLocal.activeBadge"))
                            .font(.caption2)
                            .fontWeight(.semibold)
                            .foregroundStyle(tint)
                            .padding(.horizontal, 7)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(tint.opacity(0.15)))
                    }
                    Text(ruleCountLabel(ruleCount(in: scenario)))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("·").foregroundStyle(.tertiary)
                    Text(running
                         ? (modified
                            ? L10n.format("mapLocal.scenarioOnCount", enabledMemberCount(scenario), ruleCount(in: scenario))
                            : L10n.string("mapLocal.scenarioActiveDetail"))
                         : L10n.string("mapLocal.scenarioInactiveDetail"))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            }

            Spacer()

            if case .scenario(let id) = filter, let scenario = scenario(id: id) {
                if runningScenario?.id == scenario.id {
                    if isModified(scenario) {
                        Button("mapLocal.resetScenario") { activate(scenario) }
                    }
                    Button("mapLocal.turnOff") { turnOff() }
                } else {
                    Button("mapLocal.activate") { activate(scenario) }
                        .disabled(ruleCount(in: scenario) == 0)
                }

                Menu {
                    Button("mapLocal.rename") { beginRename(scenario) }
                    Button("mapLocal.deleteScenario") { deleteScenario(scenario) }
                    Divider()
                    Button("mapLocal.captureScenario") {
                        namingIntent = .capture
                        scenarioName = ""
                        isNamingScenario = true
                    }
                    .disabled(!rules.mapLocalRules.contains { $0.isEnabled })
                } label: {
                    Image(systemName: "ellipsis")
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("mapLocal.scenarioMenuHelp")
                .accessibilityLabel(Text("mapLocal.scenarioMenuHelp"))
            }
        }
        .padding(.horizontal, 16)
        .padding(.top, 14)
        .padding(.bottom, 10)
    }

    private var filterBar: some View {
        HStack(spacing: 12) {
            TextField("mapLocal.filterPlaceholder", text: $filterText)
                .textFieldStyle(.roundedBorder)
                .frame(maxWidth: 420)

            Toggle("mapLocal.showEnabled", isOn: $showEnabledOnly)
                .toggleStyle(.checkbox)

            Spacer()
        }
        .padding(.horizontal, 16)
        .padding(.bottom, 10)
    }

    private var columnHeader: some View {
        HStack(spacing: 10) {
            // A fixed height keeps the header from absorbing the list's spare vertical
            // space; an unconstrained `Color.clear` stretches the whole row.
            Color.clear.frame(width: Self.enableColumnWidth, height: 12)
            Text("common.name").frame(width: Self.nameColumnWidth, alignment: .leading)
            Text("common.method").frame(width: Self.methodColumnWidth, alignment: .leading)
            Text("mapLocal.matchingRule").frame(width: Self.ruleColumnWidth, alignment: .leading)
                .help("mapLocal.matchingURLs")
            if !isCompact {
                Text("mapLocal.mapFrom").frame(maxWidth: .infinity, alignment: .leading)
                    .help("mapLocal.mapBody")
            } else {
                Spacer(minLength: 0)
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 16)
        .padding(.vertical, 6)
    }

    // MARK: - Sidebar rows

    private func choiceRow(_ title: String, count: Int, value: ScenarioFilter) -> some View {
        Button {
            filter = value
        } label: {
            HStack(spacing: 8) {
                Text(title).font(.callout).lineLimit(1)
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(filter == value ? Color.accentColor.opacity(0.18) : Color.clear)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 6)
        .padding(.top, 4)
    }

    private func scenarioRow(_ scenario: MapLocalScenario) -> some View {
        let running = runningScenario?.id == scenario.id
        let modified = isModified(scenario)
        let browsed = filter == .scenario(scenario.id)
        let count = ruleCount(in: scenario)
        return HStack(spacing: 7) {
            Image(systemName: running ? "circle.fill" : "circle")
                .font(.system(size: 9))
                .foregroundStyle(running ? (modified ? Color.orange : Color.green) : Color.secondary)
                .frame(width: 14, height: 20)
                .accessibilityLabel(Text(running
                    ? L10n.string(modified ? "mapLocal.modifiedBadge" : "mapLocal.activeBadge")
                    : L10n.string("mapLocal.scenarioInactiveDetail")))

            Button {
                filter = .scenario(scenario.id)
            } label: {
                Text(scenario.displayName)
                    .font(.callout)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if hoveredScenarioID == scenario.id, !running, count > 0 {
                Button("mapLocal.activate") { activate(scenario) }
                    .buttonStyle(.bordered)
                    .controlSize(.mini)
            } else {
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(minWidth: 14, alignment: .trailing)
            }
        }
        .padding(.leading, 10)
        .padding(.trailing, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(browsed ? Color.accentColor.opacity(0.18) : Color.clear)
        )
        .onHover { inside in
            if inside {
                hoveredScenarioID = scenario.id
            } else if hoveredScenarioID == scenario.id {
                hoveredScenarioID = nil
            }
        }
        .contextMenu {
            if running {
                if modified {
                    Button("mapLocal.resetScenario") { activate(scenario) }
                }
                Button("mapLocal.turnOff") { turnOff() }
            } else {
                Button("mapLocal.activate") { activate(scenario) }
                    .disabled(count == 0)
            }
            Divider()
            Button("mapLocal.rename") { beginRename(scenario) }
            Button("mapLocal.deleteScenario") { deleteScenario(scenario) }
        }
    }

    // MARK: - Rule table

    @ViewBuilder
    private var ruleList: some View {
        if visibleRules.isEmpty {
            emptyState
        } else {
            List(selection: $selection) {
                ForEach(visibleSections) { section in
                    Section {
                        ForEach(section.rules) { rule in
                            row(rule)
                                .tag(rule.id)
                                .contextMenu { contextMenu(for: rule) }
                        }
                    } header: {
                        endpointHeader(section)
                    }
                }
            }
            .listStyle(.inset(alternatesRowBackgrounds: true))
        }
    }

    private func endpointHeader(_ section: EndpointSection) -> some View {
        HStack(spacing: 8) {
            Text(verbatim: section.endpoint.label)
                .font(.system(.caption, design: .monospaced))
                .fontWeight(.semibold)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Text(ruleCountLabel(section.rules.count))
                .font(.caption)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
        .textCase(nil)
        .padding(.top, 4)
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.badge.plus")
                .font(.system(size: 30))
                .foregroundStyle(.tertiary)
            Text(emptyMessage)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if offersNewRule {
                Button(newButtonTitle) { newRule() }
                    .buttonStyle(.bordered)
            }
        }
        .padding(20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func row(_ rule: MapLocalRule) -> some View {
        let running = runningScenario
        let locked = running.map { !$0.ruleIDs.contains(rule.id) } ?? false
        return HStack(spacing: 10) {
            Toggle("", isOn: Binding(
                get: { rule.isEnabled },
                set: { rules.setMapLocalRule(id: rule.id, enabled: $0); onApply() }
            ))
            .labelsHidden()
            .toggleStyle(.checkbox)
            .frame(width: Self.enableColumnWidth)
            .disabled(locked)
            .help(Text(locked ? L10n.string("mapLocal.scenarioHelp") : ""))

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

            if isCompact {
                // At the minimum width the mock source is the first column to go; the
                // scenario hint stays, because it explains why a checkbox is unavailable.
                Spacer(minLength: 4)
                if locked, let running {
                    Text(L10n.format("mapLocal.notInScenario", running.displayName))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            } else {
                HStack(spacing: 6) {
                    Image(systemName: rule.destination.symbolName).foregroundStyle(.secondary)
                    Text(rule.destination.path.isEmpty ? L10n.string("mapLocal.notSet") : rule.destination.path)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(rule.destination.path.isEmpty ? .tertiary : .secondary)
                    if locked, let running {
                        Spacer(minLength: 8)
                        Text(L10n.format("mapLocal.notInScenario", running.displayName))
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .lineLimit(1)
                            .fixedSize()
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, 2)
        .opacity(rule.isEnabled ? 1 : 0.7)
    }

    @ViewBuilder
    private func contextMenu(for rule: MapLocalRule) -> some View {
        let locked = runningScenario.map { !$0.ruleIDs.contains(rule.id) } ?? false
        Button("common.edit") { edit(rule) }
        Button("common.duplicate") { rules.duplicateMapLocalRule(id: rule.id); onApply() }
        Button(rule.isEnabled ? L10n.string("mapLocal.disableRule") : L10n.string("mapLocal.enableRule")) {
            rules.setMapLocalRule(id: rule.id, enabled: !rule.isEnabled); onApply()
        }
        .disabled(locked && !rule.isEnabled)
        Divider()
        Button("mapLocal.showInFinder") { reveal(rule) }.disabled(rule.destination.path.isEmpty)
        Divider()
        Button("common.delete") { delete([rule.id]) }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button { newRule() } label: { Label(newButtonTitle, systemImage: "plus") }
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
                .disabled(selection == nil || selectedRule == nil)

            Button {
                if let selectedRule {
                    rules.setMapLocalRule(id: selectedRule.id, enabled: !selectedRule.isEnabled)
                    onApply()
                }
            } label: {
                Label("mapLocal.enableRule", systemImage: "checkmark.circle")
            }
            .keyboardShortcut(.space, modifiers: [])
            .disabled(!canToggle(selectedRule))

            Divider().frame(height: 18)

            Button { move(-1) } label: { Image(systemName: "arrow.up") }
                .disabled(!canMove(-1))
                .help("mapLocal.moveUpHelp")
            Button { move(1) } label: { Image(systemName: "arrow.down") }
                .disabled(!canMove(1))

            Spacer()

            Text("mapLocal.shortcuts")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    // MARK: - Derived lists

    private var existingRuleIDs: Set<UUID> {
        Set(rules.mapLocalRules.map(\.id))
    }

    private var assignedRuleIDs: Set<UUID> {
        Set(rules.mapLocalScenarios.flatMap(\.ruleIDs))
    }

    private var unassignedCount: Int {
        rules.mapLocalRules.filter { !assignedRuleIDs.contains($0.id) }.count
    }

    private var browsedRules: [MapLocalRule] {
        switch filter {
        case .all:
            return rules.mapLocalRules
        case .unassigned:
            return rules.mapLocalRules.filter { !assignedRuleIDs.contains($0.id) }
        case .scenario(let id):
            guard let scenario = scenario(id: id) else { return [] }
            let members = Set(scenario.ruleIDs)
            return rules.mapLocalRules.filter { members.contains($0.id) }
        }
    }

    private var visibleRules: [MapLocalRule] {
        var list = browsedRules
        if showEnabledOnly {
            list = list.filter(\.isEnabled)
        }
        let query = filterText.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return list }
        return list.filter { rule in
            rule.name.localizedCaseInsensitiveContains(query)
            || rule.url.localizedCaseInsensitiveContains(query)
            || rule.method.displayName.localizedCaseInsensitiveContains(query)
            || rule.destination.path.localizedCaseInsensitiveContains(query)
        }
    }

    /// Rows stay in list order but are drawn under the endpoint they answer. Which rule
    /// wins is still list order, so the sections are a reading aid, not a second ordering.
    private var visibleSections: [EndpointSection] {
        var order: [MapLocalEndpoint] = []
        var grouped: [MapLocalEndpoint: [MapLocalRule]] = [:]
        for rule in visibleRules {
            if grouped[rule.endpoint] == nil {
                order.append(rule.endpoint)
            }
            grouped[rule.endpoint, default: []].append(rule)
        }
        return order.map { EndpointSection(endpoint: $0, rules: grouped[$0] ?? []) }
    }

    private var selectedRule: MapLocalRule? {
        visibleRules.first { $0.id == selection }
    }

    /// Below this width the detail pane drops the mock-source column. The sheet can shrink
    /// to 880 points, and truncating the source path is less costly than squeezing every
    /// column; the path is still one click away in the editor.
    private var isCompact: Bool { detailWidth < 760 }

    /// The scenario the user turned on. Falls back to an exact switchboard for state
    /// loaded from disk, where the last-activated identifier is not stored.
    private var runningScenario: MapLocalScenario? {
        if let id = rules.activeMapLocalScenarioID, let scenario = scenario(id: id) {
            return scenario
        }
        return rules.mapLocalScenarios.first(where: isActive)
    }

    /// Endpoints the running scenario answers more than once. Only data that bypassed the
    /// editor can produce this; the banner is a repair hint, not a normal state.
    private var runningConflictGroups: [(endpoint: MapLocalEndpoint, count: Int)] {
        guard let running = runningScenario else { return [] }
        let memberIDs = Set(running.ruleIDs)
        var counts: [MapLocalEndpoint: Int] = [:]
        for rule in rules.mapLocalRules where memberIDs.contains(rule.id) {
            counts[rule.endpoint, default: 0] += 1
        }
        return counts
            .filter { $0.value > 1 }
            .sorted { $0.key.label < $1.key.label }
            .map { (endpoint: $0.key, count: $0.value) }
    }

    /// The scenario is running, but at least one member was switched by hand or an
    /// outsider is on, so the strict switchboard no longer matches.
    private func isModified(_ scenario: MapLocalScenario) -> Bool {
        runningScenario?.id == scenario.id && !isActive(scenario)
    }

    private func enabledMemberCount(_ scenario: MapLocalScenario) -> Int {
        let enabled = Set(rules.mapLocalRules.filter(\.isEnabled).map(\.id))
        let existing = existingRuleIDs
        return scenario.ruleIDs.filter { existing.contains($0) && enabled.contains($0) }.count
    }

    /// While a scenario runs, only its members have a live switch. An outsider is off
    /// and cannot be turned on without leaving the scenario first.
    private func canToggle(_ rule: MapLocalRule?) -> Bool {
        guard let rule else { return false }
        guard let running = runningScenario else { return true }
        return running.ruleIDs.contains(rule.id)
    }

    private var offersNewRule: Bool {
        browsedRules.isEmpty
        && filterText.trimmingCharacters(in: .whitespaces).isEmpty
        && !showEnabledOnly
        && !rules.mapLocalRules.isEmpty
    }

    private var emptyMessage: String {
        if !filterText.trimmingCharacters(in: .whitespaces).isEmpty {
            return L10n.format("mapLocal.noMatches", filterText.trimmingCharacters(in: .whitespaces))
        }
        if showEnabledOnly {
            return L10n.string("mapLocal.noEnabledRules")
        }
        if rules.mapLocalRules.isEmpty {
            return L10n.string("mapLocal.emptyHint")
        }
        switch filter {
        case .scenario:
            return L10n.string("mapLocal.scenarioEmpty")
        case .unassigned:
            return L10n.string("mapLocal.unassignedEmpty")
        case .all:
            return L10n.string("mapLocal.emptyHint")
        }
    }

    private var newButtonTitle: String {
        if case .scenario(let id) = filter, let scenario = scenario(id: id) {
            return L10n.format("mapLocal.newInScenario", scenario.displayName)
        }
        return L10n.string("mapLocal.newRule")
    }

    private var isRenamingScenario: Binding<Bool> {
        Binding(
            get: { renamingScenarioID != nil },
            set: { if !$0 { renamingScenarioID = nil } }
        )
    }

    private var renameCollides: Bool {
        guard let id = renamingScenarioID else { return false }
        let trimmed = renameText.trimmingCharacters(in: .whitespaces)
        return rules.mapLocalScenarios.contains {
            $0.id != id && $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private var scenarioNameTaken: Bool {
        let trimmed = scenarioName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return false }
        return rules.mapLocalScenarios.contains {
            $0.name.caseInsensitiveCompare(trimmed) == .orderedSame
        }
    }

    private func ruleCount(in scenario: MapLocalScenario) -> Int {
        let existing = existingRuleIDs
        return scenario.ruleIDs.filter { existing.contains($0) }.count
    }

    private func scenario(id: UUID) -> MapLocalScenario? {
        rules.mapLocalScenarios.first { $0.id == id }
    }

    /// An empty scenario is never reported as running: with every rule off it would
    /// otherwise satisfy the exact-match check and light the header pill for nothing.
    private func isActive(_ scenario: MapLocalScenario) -> Bool {
        ruleCount(in: scenario) > 0 && rules.isMapLocalScenarioActive(scenario)
    }

    private func ruleCountLabel(_ count: Int) -> String {
        count == 1
            ? L10n.string("mapLocal.ruleCountOne")
            : L10n.format("mapLocal.ruleCount", count)
    }

    // MARK: - Actions

    private func activate(_ scenario: MapLocalScenario) {
        rules.activateMapLocalScenario(id: scenario.id)
        onApply()
    }

    private func turnOff() {
        rules.turnOffMapLocalRules()
        onApply()
    }

    /// The sidebar's plus only creates the container. Capturing the enabled rules is the
    /// scenario menu's job, so the two actions cannot be confused for one another.
    private func submitScenarioName() {
        let name = scenarioName.trimmingCharacters(in: .whitespaces)
        guard !name.isEmpty else { return }
        switch namingIntent {
        case .newScenario:
            guard !scenarioNameTaken else { return }
            rules.saveMapLocalScenario(MapLocalScenario(name: name))
            if let saved = rules.mapLocalScenarios.first(where: {
                $0.name.caseInsensitiveCompare(name) == .orderedSame
            }) {
                filter = .scenario(saved.id)
            }
        case .capture:
            captureScenario(named: name)
        }
        scenarioName = ""
        onApply()
    }

    private func captureScenario(named name: String) {
        let enabled = rules.mapLocalRules.filter(\.isEnabled).map(\.id)
        guard !enabled.isEmpty else { return }
        rules.saveMapLocalScenario(MapLocalScenario(name: name, ruleIDs: enabled))
        if let saved = rules.mapLocalScenarios.first(where: {
            $0.name.caseInsensitiveCompare(name) == .orderedSame
        }) {
            filter = .scenario(saved.id)
            // The snapshot is exactly the switchboard that is on now, so it becomes the
            // active scenario instead of leaving two scenarios claiming the same state.
            rules.activateMapLocalScenario(id: saved.id)
        }
    }

    private func presentSwapNotice(_ swaps: [MapLocalScenarioSwap], addedName: String) {
        let message: String
        if swaps.count == 1, let swap = swaps.first {
            message = L10n.format(
                "mapLocal.swapToast",
                swap.scenarioName,
                addedName,
                swap.replacedRuleName
            )
        } else {
            message = L10n.format(
                "mapLocal.swapToastMany",
                Set(swaps.map(\.scenarioID)).count,
                addedName
            )
        }
        swapNoticeTask?.cancel()
        swapNotice = SwapNotice(message: message, swaps: swaps)
        swapNoticeTask = Task {
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard !Task.isCancelled else { return }
            await MainActor.run { swapNotice = nil }
        }
    }

    private func undoSwap(_ notice: SwapNotice) {
        swapNoticeTask?.cancel()
        for swap in notice.swaps.reversed() {
            rules.undoMapLocalScenarioSwap(swap)
        }
        swapNotice = nil
        onApply()
    }

    private func swapNoticeView(_ notice: SwapNotice) -> some View {
        HStack(spacing: 10) {
            Text(notice.message)
                .font(.callout)
                .lineLimit(2)
            Button("common.undo") { undoSwap(notice) }
                .buttonStyle(.borderless)
                .fontWeight(.semibold)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 9)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().stroke(Color(NSColor.separatorColor), lineWidth: 1))
        .shadow(radius: 8, y: 3)
    }

    private func beginRename(_ scenario: MapLocalScenario) {
        renamingScenarioID = scenario.id
        renameText = scenario.displayName
    }

    private func commitRename() {
        guard let id = renamingScenarioID else { return }
        if rules.renameMapLocalScenario(id: id, to: renameText) {
            onApply()
        }
        renamingScenarioID = nil
        renameText = ""
    }

    private func deleteScenario(_ scenario: MapLocalScenario) {
        rules.removeMapLocalScenario(id: scenario.id)
        if filter == .scenario(scenario.id) {
            filter = .all
        }
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
        var initial: Set<UUID> = []
        if case .scenario(let id) = filter {
            initial = [id]
        }
        editing = EditorTarget(rule: rule, isNew: true, initialScenarioIDs: initial)
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

    private func reveal(_ rule: MapLocalRule) {
        guard !rule.destination.path.isEmpty else { return }
        let url = URL(fileURLWithPath: (rule.destination.path as NSString).expandingTildeInPath)
        NSWorkspace.shared.activateFileViewerSelecting([url])
    }
}

// MARK: - Editor

/// The rule editor: name, matching rule, scenario membership, what to map to, and the delay.
struct MapLocalEditorView: View {
    init(
        rule: MapLocalRule,
        isNew: Bool,
        scenarios: [MapLocalScenario] = [],
        existingRules: [MapLocalRule] = [],
        initialScenarioIDs: Set<UUID> = [],
        onSave: @escaping (MapLocalRule, Set<UUID>, [String]) -> Void
    ) {
        self.isNew = isNew
        self.scenarios = scenarios
        self.existingRules = existingRules
        self.onSave = onSave
        _draft = State(initialValue: rule)
        let memberships = Set(scenarios.filter { $0.ruleIDs.contains(rule.id) }.map(\.id))
            .union(initialScenarioIDs)
        _selectedScenarioIDs = State(initialValue: memberships)
        _pendingScenarioNames = State(initialValue: [])
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
    private let existingRules: [MapLocalRule]
    private let onSave: (MapLocalRule, Set<UUID>, [String]) -> Void

    private var existingRuleIDs: Set<UUID> { Set(existingRules.map(\.id)) }

    @Environment(\.dismiss) private var dismiss
    @State private var draft: MapLocalRule
    @State private var path: String
    @State private var isDirectory: Bool
    @State private var responseContent: String
    @State private var selectedScenarioIDs: Set<UUID>
    @State private var pendingScenarioNames: [String]
    @State private var scenarioQuery = ""
    @State private var isScenarioPickerPresented = false
    @State private var isShowingReplaceConfirmation = false

    private static let methods = ["", "GET", "POST", "PUT", "PATCH", "DELETE", "HEAD", "OPTIONS", "TRACE"]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()

            VStack(alignment: .leading, spacing: 14) {
                matchingRuleCard
                scenariosCard
                responseCard
            }
            .padding(16)

            Divider()
            footer
        }
        .frame(width: 880, height: 700)
        .confirmationDialog(
            "mapLocal.replaceTitle",
            isPresented: $isShowingReplaceConfirmation,
            titleVisibility: .visible
        ) {
            Button("mapLocal.replaceAction") { persist() }
            Button("common.cancel", role: .cancel) {}
        } message: {
            Text(replacementMessage)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(isNew ? L10n.string("mapLocal.createTitle") : L10n.string("mapLocal.editTitle"))
                .font(.title3).bold()
            Text("mapLocal.formSubtitle")
                .font(.caption)
                .foregroundStyle(.secondary)
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
                    }
                    .labelsHidden()
                    .frame(width: 160)

                    Text("mapLocal.delayLabel")
                        .foregroundStyle(.secondary)

                    Picker("", selection: delayBinding) {
                        ForEach(MapLocalDelay.allCases) { Text($0.displayName).tag($0.rawValue) }
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

    /// Scenarios sit directly under the matching rule: whether a rule runs at all is a
    /// more important decision than which file answers it.
    private var scenariosCard: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("mapLocal.scenarios")
                    .font(.headline)
                Spacer()
                Text("mapLocal.optional")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            FlowLayout(spacing: 6) {
                ForEach(selectedScenarios) { scenario in
                    scenarioChip(scenario.displayName, remove: { selectedScenarioIDs.remove(scenario.id) })
                }
                ForEach(pendingScenarioNames, id: \.self) { name in
                    scenarioChip(name, remove: { pendingScenarioNames.removeAll { $0 == name } })
                }

                Button {
                    isScenarioPickerPresented = true
                } label: {
                    Label("mapLocal.addScenario", systemImage: "plus")
                }
                .buttonStyle(.borderless)
                .popover(isPresented: $isScenarioPickerPresented, arrowEdge: .bottom) {
                    scenarioPicker
                }
            }

            Text("mapLocal.scenarioPickerHelp")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
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
                        .frame(minHeight: 110, maxHeight: .infinity)
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

    // MARK: - Scenario chips

    private var selectedScenarios: [MapLocalScenario] {
        scenarios.filter { selectedScenarioIDs.contains($0.id) }
    }

    private func scenarioChip(_ name: String, remove: @escaping () -> Void) -> some View {
        ScenarioChipView(name: name, remove: remove)
    }

    private var scenarioPicker: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("mapLocal.searchScenarios", text: $scenarioQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit { commitScenarioQuery() }

            Divider()

            if filteredScenarios.isEmpty {
                Text(scenarioQuery.trimmingCharacters(in: .whitespaces).isEmpty
                     ? L10n.string("mapLocal.noScenarios")
                     : L10n.string("mapLocal.noScenarioMatches"))
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(.vertical, 4)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(filteredScenarios) { scenario in
                            Toggle(isOn: membershipBinding(scenario.id)) {
                                VStack(alignment: .leading, spacing: 1) {
                                    HStack(spacing: 8) {
                                        Text(scenario.displayName)
                                            .lineLimit(1)
                                        Spacer()
                                        Text(verbatim: "\(scenarioRuleCount(scenario))")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .monospacedDigit()
                                    }
                                    // Only a checked row can replace anything, so the hint
                                    // appears exactly where the consequence is chosen.
                                    if selectedScenarioIDs.contains(scenario.id),
                                       let replaced = replacement(in: scenario) {
                                        Text(L10n.format("mapLocal.replacesRule", replaced.displayName))
                                            .font(.caption2)
                                            .foregroundStyle(.secondary)
                                    }
                                }
                            }
                            .toggleStyle(.checkbox)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.vertical, 2)
                        }
                    }
                }
                .frame(maxHeight: 180)
            }

            if canCreateScenario {
                Divider()
                Button {
                    commitScenarioQuery()
                } label: {
                    Label(
                        L10n.format("mapLocal.createScenario", scenarioQuery.trimmingCharacters(in: .whitespaces)),
                        systemImage: "plus"
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(12)
        .frame(width: 320)
    }

    private var filteredScenarios: [MapLocalScenario] {
        let query = scenarioQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return scenarios }
        return scenarios.filter { $0.displayName.localizedCaseInsensitiveContains(query) }
    }

    /// Count only rules that still exist, matching the list's counts. A rule deleted since
    /// the scenario was captured leaves its identifier behind by design.
    private func scenarioRuleCount(_ scenario: MapLocalScenario) -> Int {
        scenario.ruleIDs.filter(existingRuleIDs.contains).count
    }

    /// The existing member this rule would replace in `scenario`, if any.
    private func replacement(in scenario: MapLocalScenario) -> MapLocalRule? {
        scenario.ruleIDs
            .filter { $0 != draft.id }
            .compactMap { id in existingRules.first { $0.id == id } }
            .first { $0.endpoint == draft.endpoint }
    }

    private var replacementPairs: [(scenario: MapLocalScenario, replaced: MapLocalRule)] {
        selectedScenarios.compactMap { scenario in
            replacement(in: scenario).map { (scenario: scenario, replaced: $0) }
        }
    }

    private var replacementMessage: String {
        replacementPairs.map { pair in
            L10n.format(
                "mapLocal.replaceMessage",
                pair.scenario.displayName,
                pair.replaced.displayName,
                draft.endpoint.label
            )
        }
        .joined(separator: "\n")
    }

    private var canCreateScenario: Bool {
        let query = scenarioQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return false }
        let existing = scenarios.contains {
            $0.name.caseInsensitiveCompare(query) == .orderedSame
        }
        let pending = pendingScenarioNames.contains {
            $0.caseInsensitiveCompare(query) == .orderedSame
        }
        return !existing && !pending
    }

    private func membershipBinding(_ id: UUID) -> Binding<Bool> {
        Binding(
            get: { selectedScenarioIDs.contains(id) },
            set: { isOn in
                if isOn {
                    selectedScenarioIDs.insert(id)
                } else {
                    selectedScenarioIDs.remove(id)
                }
            }
        )
    }

    /// A query that names an existing scenario checks it instead of creating a duplicate.
    /// Anything else becomes a pending chip, saved with the rule.
    private func commitScenarioQuery() {
        let query = scenarioQuery.trimmingCharacters(in: .whitespaces)
        guard !query.isEmpty else { return }
        if let existing = scenarios.first(where: { $0.name.caseInsensitiveCompare(query) == .orderedSame }) {
            selectedScenarioIDs.insert(existing.id)
        } else if !pendingScenarioNames.contains(where: { $0.caseInsensitiveCompare(query) == .orderedSame }) {
            pendingScenarioNames.append(query)
        }
        scenarioQuery = ""
        isScenarioPickerPresented = false
    }

    private func formRow<Content: View>(
        _ label: LocalizedStringKey,
        @ViewBuilder content: () -> Content
    ) -> some View {
        HStack(alignment: .center, spacing: 12) {
            Text(label)
                .frame(width: Self.labelColumnWidth, alignment: .trailing)
                .foregroundStyle(.secondary)
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
            get: { MapLocalDelay.closest(to: draft.responseDelay)?.rawValue ?? draft.responseDelay },
            set: { draft.responseDelay = $0 }
        )
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

    // MARK: - Actions

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

        // A replacement changes another rule's membership, so it needs a deliberate yes.
        // Membership itself is only written after this point, never while ticking chips.
        if replacementPairs.isEmpty {
            persist()
        } else {
            isShowingReplaceConfirmation = true
        }
    }

    private func persist() {
        onSave(draft, selectedScenarioIDs, pendingScenarioNames)
        dismiss()
    }
}

/// Reports the detail pane's width so the list can drop its widest column instead of
/// squeezing every column when the sheet is at its 880-point minimum.
private struct DetailWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 900

    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = nextValue()
    }
}

// FlowLayout and chip/pill components are shared and reused from MapLocalComponents.swift
