import SwiftUI
import FlowKit
import RuleKit
import SystemKit
import CodeGenKit
struct MainView: View {
    @EnvironmentObject var model: AppModel
    /// Observed directly so captured traffic redraws the table. `AppModel` does not
    /// republish its store, and the store coalesces snapshot bursts into `revision` bumps.
    @ObservedObject var flowStore: FlowStore
    /// Observed so pinning or saving an entry redraws the sidebar and its collection rows.
    @ObservedObject var marks: SidebarMarks
    @State private var filter = FlowFilter()
    @State private var selection: UUID?
    @State private var showSSLProxying = false
    @State private var showLog = false
    /// Set when capture emptied the table and left a device selection whose emulator stopped.
    @State private var deviceGone = false

    var body: some View {
        // Derived once per pass. `flows` was a computed property read five times, each
        // read re-filtering the whole store.
        let flows = scopedFlows()
        let summary = FlowSummary(flowStore.flows)
        let selectedFlow = flows.first { $0.id == selection }
        return VStack(spacing: 0) {
            controlBar(flows: flows)
            if let owner = model.externalOwner { externalOwnerBanner(owner) }
            if model.staleSystemProxy { staleProxyBanner }
            if trustCertificateBanner { certificateTrustBanner }
            Divider()
            filterBar
            Divider()
            HSplitView {
                sidebarView(summary: summary)
                VSplitView {
                    trafficTable(flows: flows, selectedFlow: selectedFlow)
                        .frame(minHeight: 200, idealHeight: 350)
                    detailPane(selectedFlow: selectedFlow)
                        .frame(minHeight: 200)
                }
            }
        }
        .sheet(isPresented: $showSSLProxying) {
            SSLProxyingView(rules: model.ruleStore) { model.applyRules() }
        }
        .sheet(isPresented: $model.showMapLocalWindow) {
            MapLocalView(rules: model.ruleStore) { model.applyRules() }
        }
        .sheet(isPresented: $model.showPluginStore) {
            PluginStoreView(coordinator: model.pluginCoordinator)
        }
        .sheet(item: Binding(
            get: { model.pluginCoordinator.activeConsentRequest },
            set: { if $0 == nil { model.pluginCoordinator.resolveConsent(granted: false) } }
        )) { request in
            PluginConsentView(request: request) { granted in
                model.pluginCoordinator.resolveConsent(granted: granted)
            }
        }
        .sheet(isPresented: $model.showCertificateSheet) {
            CertificatesView().environmentObject(model)
        }
        .sheet(isPresented: $showLog) { LogView().environmentObject(model) }
        .sheet(isPresented: $model.showAndroidEmulatorGuide) {
            AndroidEmulatorGuideView().environmentObject(model)
        }
        .sheet(isPresented: $model.showAndroidDeviceGuide) {
            AndroidDeviceGuideView().environmentObject(model)
        }
        .sheet(isPresented: $model.showBrowserExtensionPanel) {
            BrowserExtensionPanelView().environmentObject(model)
        }
        .sheet(isPresented: $model.showCommandLinePanel) {
            CommandLineToolPanelView().environmentObject(model)
        }
        .overlay(alignment: .bottomTrailing) {
            // One balloon at a time: the first-run error-reporting question comes first, and
            // an update offer waits until that launch has asked it. Both read as the same
            // gesture in the same corner, so stacking them would be two things to dismiss.
            if model.showErrorReportingPrompt {
                ErrorReportingPromptView()
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            } else if model.showUpdatePrompt {
                UpdatePromptView()
                    .padding(16)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
            }
        }
        .animation(.easeOut(duration: 0.2), value: model.showErrorReportingPrompt)
        .animation(.easeOut(duration: 0.2), value: model.showUpdatePrompt)
        .alert("common.error", isPresented: errorBinding) {
            Button("common.ok") { model.lastError = nil }
        } message: {
            Text(model.lastError ?? "")
        }
        .onReceive(flowStore.$revision) { _ in
            guard flowStore.flows.isEmpty else { return }
            selection = nil
            switch filter.sidebarSelection {
            case .client, .app: filter.sidebarSelection = .all
            case .device(let serial) where !model.connectedDevices.contains(where: { $0.serial == serial }):
                // The chosen emulator stopped: say so next to the empty table rather than
                // silently widening the list back to every device's traffic.
                filter.sidebarSelection = .all
                deviceGone = true
            default: break
            }
        }
        .onAppear {
            model.refreshExternalOwner()
            model.refreshSystemProxyState()
            model.detectStaleSystemProxy()
            model.applyCommandLineOptions()
            model.beginExternalOwnerWatch()
            model.presentErrorReportingPromptIfNeeded()
            model.checkForUpdatesIfNeeded()
        }
    }

    /// The rows the traffic table shows: the text/method/error filter, plus the sidebar
    /// collection scope. `.pinned` and `.saved` are not flow predicates — they narrow the
    /// list to the flows owned by the entries those collections list.
    private func scopedFlows() -> [Flow] {
        var effective = filter
        let collection = filter.sidebarSelection
        if collection == .pinned || collection == .saved { effective.sidebarSelection = .all }
        let base = effective.apply(to: flowStore.flows)
        switch collection {
        case .pinned: return base.filter { marks.isPinned($0) }
        case .saved: return base.filter { marks.isSaved($0) }
        default: return base
        }
    }

    private func sidebarView(summary: FlowSummary) -> some View {
        List(selection: sidebarSelection) {
            Section("main.favorites") {
                sidebarRow(L10n.string("main.all"), systemImage: "tray", selection: .all, count: summary.total)
                sidebarRow(L10n.string("main.pinned"), systemImage: "pin", selection: .pinned, count: marks.pinned.count)
                sidebarRow(L10n.string("main.saved"), systemImage: "bookmark", selection: .saved, count: marks.saved.count)
            }

            switch filter.sidebarSelection {
            case .pinned:
                pinnedSections()
            case .saved:
                savedSection()
            default:
                allSections(summary: summary)
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
    }

    /// The Devices, Apps and Hosts sections in full, as the "All" collection lists them.
    @ViewBuilder
    private func allSections(summary: FlowSummary) -> some View {
        if !model.connectedDevices.isEmpty {
            let counts = DeviceFlowCounts(flowStore.flows)
            Section(header: Text(L10n.format("main.devices", model.connectedDevices.count))) {
                ForEach(model.connectedDevices) { device in
                    entityRow(
                        entity: .device(serial: device.serial, label: L10n.string(device.displayName)),
                        selection: .device(device.serial),
                        count: counts.count(for: device.serial)
                    ) {
                        Label {
                            Text(L10n.string(device.displayName)).lineLimit(1)
                        } icon: {
                            Image(systemName: device.isEmulator ? "android" : "candybarphone")
                                .help(L10n.string("main.devicesHelp"))
                        }
                    }
                }
            }
        }

        if !summary.apps.isEmpty {
            Section(header: Text(L10n.format("main.apps", summary.apps.count))) {
                ForEach(summary.apps) { entry in
                    entityRow(entity: .app(entry.app), selection: .client(entry.id), count: entry.count) {
                        ClientAppLabel(app: entry.app, showsIdentity: summary.duplicateAppNames.contains(entry.app.name))
                    }
                }
            }
        }

        Section(header: Text(L10n.format("main.domains", summary.domains.count))) {
            ForEach(summary.domains, id: \.self) { domain in
                entityRow(entity: .domain(domain), selection: .domain(domain), count: summary.domainCount(domain)) {
                    Label(domain, systemImage: "globe")
                }
            }
        }
    }

    /// The pinned entries, still grouped under their own sections.
    @ViewBuilder
    private func pinnedSections() -> some View {
        if marks.pinned.isEmpty {
            collectionHint(title: "main.noPinnedEntries", hint: "main.pinHint")
        } else {
            let devices = marks.pinned.filter { $0.kind == .device }
            let apps = marks.pinned.filter { $0.kind == .app }
            let domains = marks.pinned.filter { $0.kind == .domain }
            if !devices.isEmpty {
                Section(header: Text(L10n.format("main.devices", devices.count))) {
                    ForEach(devices) { markRow($0) }
                }
            }
            if !apps.isEmpty {
                Section(header: Text(L10n.format("main.apps", apps.count))) {
                    ForEach(apps) { markRow($0) }
                }
            }
            if !domains.isEmpty {
                Section(header: Text(L10n.format("main.domains", domains.count))) {
                    ForEach(domains) { markRow($0) }
                }
            }
        }
    }

    /// The saved entries, as one bookmark list rather than grouped sections.
    @ViewBuilder
    private func savedSection() -> some View {
        if marks.saved.isEmpty {
            collectionHint(title: "main.noSavedEntries", hint: "main.saveHint")
        } else {
            Section(header: Text(L10n.string("main.saved"))) {
                ForEach(marks.saved) { markRow($0) }
            }
        }
    }

    /// Stands in for a section whose collection has nothing in it yet.
    private func collectionHint(title: String, hint: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(L10n.string(title))
            Text(L10n.string(hint))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// A row for a mark that is not sourced from the live summary, so a pinned or saved entry
    /// whose device stopped, or which has no traffic this session, still lists.
    private func markRow(_ entity: SidebarEntity) -> some View {
        entityRow(entity: entity, selection: selection(for: entity), count: flowCount(for: entity)) {
            Label(entity.label, systemImage: icon(for: entity))
        }
    }

    private func selection(for entity: SidebarEntity) -> SidebarSelection {
        switch entity.kind {
        case .device: return .device(entity.key)
        case .app: return .client(entity.key)
        case .domain: return .domain(entity.key)
        }
    }

    private func icon(for entity: SidebarEntity) -> String {
        switch entity.kind {
        case .device:
            let emulator = model.connectedDevices.first { $0.serial == entity.key }?.isEmulator ?? false
            return emulator ? "android" : "candybarphone"
        case .app: return "app"
        case .domain: return "globe"
        }
    }

    private func flowCount(for entity: SidebarEntity) -> Int {
        flowStore.flows.lazy.filter { entity.matches($0) }.count
    }

    private var sidebarSelection: Binding<SidebarSelection?> {
        Binding(
            get: { filter.sidebarSelection },
            set: {
                guard let selection = $0 else { return }
                filter.sidebarSelection = selection
                deviceGone = false
            }
        )
    }

    /// A Collections row: All, Pinned or Saved. No pin/save menu — these are the collections.
    private func sidebarRow(_ title: String, systemImage: String, selection: SidebarSelection, count: Int) -> some View {
        HStack {
            Label(title, systemImage: systemImage)
                .lineLimit(1)
            Spacer()
            sidebarCount(count)
        }
        .contentShape(Rectangle())
        .tag(selection)
    }

    /// One entry in the Devices/Apps/Hosts sections. Carries the pin and bookmark marks and
    /// the context menu that toggles them. The device Help tooltip sits on the icon alone:
    /// inside the Label it swallows the click before the row can be selected, because the
    /// tooltip takes hover input across the whole row.
    private func entityRow<Label: View>(
        entity: SidebarEntity,
        selection: SidebarSelection,
        count: Int,
        @ViewBuilder label: () -> Label
    ) -> some View {
        HStack(spacing: 6) {
            label()
                .lineLimit(1)
            Spacer()
            if marks.isPinned(entity) { markGlyph("pin.fill") }
            if marks.isSaved(entity) { markGlyph("bookmark.fill") }
            sidebarCount(count)
        }
        .contentShape(Rectangle())
        .tag(selection)
        .contextMenu {
            Button(marks.isPinned(entity) ? "main.unpin" : "main.pin") { marks.togglePin(entity) }
            Button(marks.isSaved(entity) ? "main.unsave" : "main.save") { marks.toggleSave(entity) }
        }
    }

    private func markGlyph(_ name: String) -> some View {
        Image(systemName: name)
            .font(.caption2)
            .foregroundStyle(.secondary)
            .accessibilityHidden(true)
    }

    private func sidebarCount(_ count: Int) -> some View {
        Text(verbatim: "\(count)")
            .font(.caption)
            .monospacedDigit()
            .accessibilityLabel(Text(L10n.format("main.flowCount", count)))
    }

    private struct AppSummary: Identifiable {
        let id: String
        var app: ClientApp
        var count = 0
    }

    /// Counts all captured flows in one pass, independent of active filters.
    private struct FlowSummary {
        let total: Int
        let apps: [AppSummary]
        let duplicateAppNames: Set<String>
        let domains: [String]
        private let domainCounts: [String: Int]

        init(_ flows: [Flow]) {
            var apps: [String: AppSummary] = [:]
            var domainCounts: [String: Int] = [:]
            for flow in flows {
                // A flow already credited to a device is not also counted under the process
                // that relayed it: the emulator's `netsimd` would otherwise list the device's
                // traffic twice, once as the device and once as the relay.
                if let app = flow.clientApp, flow.connectedDevice == nil {
                    let id = app.id
                    apps[id, default: AppSummary(id: id, app: app)].count += 1
                    if apps[id]?.app.path == nil, app.path != nil {
                        apps[id]?.app = app
                    }
                }
                domainCounts[flow.host, default: 0] += 1
            }
            var names: Set<String> = []
            var duplicateNames: Set<String> = []
            for entry in apps.values where !names.insert(entry.app.name).inserted {
                duplicateNames.insert(entry.app.name)
            }
            self.total = flows.count
            self.apps = apps.values.sorted {
                let order = $0.app.name.localizedStandardCompare($1.app.name)
                return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
            }
            self.duplicateAppNames = duplicateNames
            self.domainCounts = domainCounts
            self.domains = domainCounts.keys.sorted()
        }

        func domainCount(_ domain: String) -> Int { domainCounts[domain] ?? 0 }
    }

    /// Flows per connected device, counted in one pass like `FlowSummary`.
    private struct DeviceFlowCounts {
        private var counts: [String: Int] = [:]

        init(_ flows: [Flow]) {
            for flow in flows {
                guard let serial = flow.connectedDevice?.serial else { continue }
                counts[serial, default: 0] += 1
            }
        }

        func count(for serial: String) -> Int { counts[serial] ?? 0 }
    }

    private var errorBinding: Binding<Bool> {
        Binding(get: { model.lastError != nil }, set: { if !$0 { model.lastError = nil } })
    }

    // MARK: - Bars

    /// True when any engine answers on the port — ours, or the CLI we attached to.
    private var proxyIsListening: Bool { model.isRunning || model.externalOwner != nil }

    private var startButtonTitle: String {
        if model.isRunning { return L10n.string("common.stop") }
        return model.externalOwner == nil ? L10n.string("common.start") : L10n.string("common.hostHere")
    }

    private var startButtonSymbol: String {
        if model.isRunning { return "stop.fill" }
        return model.externalOwner == nil ? "play.fill" : "arrow.left.arrow.right"
    }

    /// The address actually listening, whoever owns it. Reporting "Not running" while the
    /// CLI serves would be the one lie that makes the two tools look broken together.
    private var statusText: String {
        if model.isRunning { return L10n.format("main.localAddress", model.port) }
        if let owner = model.externalOwner {
            return L10n.format(
                "main.localAddressWithOwner",
                owner.httpPort,
                owner.owner == .cli ? "ProxyMaxx CLI" : L10n.string("common.anotherApp")
            )
        }
        return L10n.string("common.notRunning")
    }

    private func controlBar(flows: [Flow]) -> some View {
        HStack(spacing: 12) {
            Button {
                if model.isRunning {
                    model.stop()
                } else if model.externalOwner != nil {
                    model.takeOverExternalProxy()
                } else {
                    model.start()
                }
            } label: {
                Label(startButtonTitle, systemImage: startButtonSymbol)
            }
            .buttonStyle(.borderedProminent)
            .tint(model.isRunning ? .red : .accentColor)

            HStack(spacing: 6) {
                Circle()
                    .fill(proxyIsListening ? Color.green : Color.secondary)
                    .frame(width: 8, height: 8)
                Text(statusText)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }

            Divider().frame(height: 18)

            Toggle("main.systemProxy", isOn: Binding(
                get: { model.systemProxyEnabled },
                set: { model.setSystemProxy($0) }
            ))
            .toggleStyle(.switch)
            .disabled(!proxyIsListening)

            Spacer()

            Text(L10n.format("main.flowCount", flows.count))
                .font(.callout)
                .foregroundStyle(.secondary)
                .monospacedDigit()

            Button { showSSLProxying = true } label: { Label("common.sslProxying", systemImage: "lock.shield") }
            Button { model.showMapLocalWindow = true } label: { Label("common.mapLocal", systemImage: "doc.badge.gearshape") }
            Button { model.showPluginStore = true } label: { Label("common.plugins", systemImage: "puzzlepiece.extension") }
            Button { model.showCertificateSheet = true } label: { Label("common.certificates", systemImage: "checkmark.seal") }
            Button {
                model.refreshAndroidDevices()
                model.showAndroidEmulatorGuide = true
            } label: {
                Label("common.android", systemImage: "candybarphone")
            }
            Button { showLog = true } label: { Label("common.log", systemImage: "list.bullet.rectangle") }
            Button { model.clearSession() } label: { Label("common.clear", systemImage: "trash") }
                .disabled(flowStore.flows.isEmpty)
        }
        .labelStyle(.titleAndIcon)
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    /// Shown while `proxymaxx-cli serve` owns the engine instead of this app. The two are one
    /// tool over one session, so the banner says traffic still appears here; it only names
    /// who is running the engine, and offers to move that role into the window.
    private func externalOwnerBanner(_ owner: ProxyRegistryEntry) -> some View {
        let ownerLabel = owner.owner == .cli ? "ProxyMaxx CLI" : L10n.string("common.anotherAppInstance")
        let socks = owner.socksPort.map { L10n.format("main.socksSuffix", $0) } ?? ""
        return HStack(spacing: 10) {
            Image(systemName: "terminal.fill").foregroundStyle(.indigo)
            Text(L10n.format("main.engineHosted", ownerLabel, owner.pid, owner.httpPort, socks))
                .font(.callout)
            Spacer()
            Button("main.hostHereInstead") { model.takeOverExternalProxy() }
                .buttonStyle(.bordered)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.indigo.opacity(0.14))
    }

    /// Shown when a previous run left the system pointed at a port with no listener.
    private var staleProxyBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
            Text(L10n.format("main.systemProxyStale", model.port))
                .font(.callout)
            Spacer()
            Button("common.restore") { model.restoreSystemProxy() }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.16))
    }

    /// True when a System Proxy request was refused for want of a trusted root certificate,
    /// and it still is. Deriving the second half from `certificateInstalled` clears the
    /// banner the moment the certificate is trusted, however it was trusted.
    private var trustCertificateBanner: Bool {
        model.trustCertificateRequired && !model.certificateInstalled
    }

    /// Shown when the System Proxy was refused because the root certificate is not trusted.
    ///
    /// The toggle cannot do what was asked until a second step happens elsewhere in the
    /// app, so the refusal carries that step as a button rather than an alert that only
    /// reports failure. The seal mark is the one the toolbar's Certificates button uses,
    /// so the banner and its destination read as the same place.
    private var certificateTrustBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "checkmark.seal").foregroundStyle(.orange)
            Text(L10n.string("main.trustCertificateRequired"))
                .font(.callout)
            Spacer()
            Button("main.trustCertificateAction") { model.showCertificateSheet = true }
                .buttonStyle(.borderedProminent)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.orange.opacity(0.16))
    }

    private var filterBar: some View {
        HStack(spacing: 10) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("main.filterPlaceholder", text: $filter.text)
                .textFieldStyle(.plain)

            Picker("", selection: $filter.method) {
                ForEach(FlowFilter.methods, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden()
            .frame(width: 110)

            Toggle("main.errorsOnly", isOn: $filter.onlyErrors)
                .toggleStyle(.checkbox)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    // MARK: - Table

    private func trafficTable(flows: [Flow], selectedFlow: Flow?) -> some View {
        Table(flows, selection: $selection) {
            TableColumn("common.method") { flow in
                Text(flow.method)
                    .font(.system(.caption, design: .monospaced))
                    .fontWeight(.semibold)
                    .foregroundStyle(Self.methodColor(flow.method))
            }
            .width(64)

            TableColumn("common.status") { flow in statusCell(flow) }.width(62)

            TableColumn("common.host") { flow in
                Text(flow.host).lineLimit(1)
            }

            TableColumn("common.path") { flow in
                Text(flow.path).lineLimit(1).truncationMode(.middle).help(flow.url)
            }

            TableColumn("common.size") { flow in
                Text(Self.sizeText(flow))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(70)

            TableColumn("common.time") { flow in
                Text(Self.timeText(flow))
                    .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            .width(64)

            TableColumn("common.client") { flow in
                if let device = flow.connectedDevice {
                    Label(device.name, systemImage: "candybarphone")
                        .font(.caption)
                        .lineLimit(1)
                        .help(device.address)
                } else if flow.origin == .remoteDevice {
                    Text("client.remoteDevice")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help(Text(verbatim: flow.clientAddress ?? ""))
                } else if let app = flow.clientApp {
                    ClientAppLabel(app: app)
                        .font(.caption)
                } else {
                    Text("client.unknown")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .help("client.unavailable")
                }
            }
            .width(min: 120, ideal: 160, max: 240)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .overlay {
            if flows.isEmpty {
                VStack(spacing: 6) {
                    if deviceGone {
                        Text("main.deviceStopped")
                        Text("main.devicesHelp").font(.callout).foregroundStyle(.secondary)
                    } else if case .pinned = filter.sidebarSelection, marks.pinned.isEmpty {
                        Text("main.noPinnedEntries")
                        Text("main.pinHint").font(.callout).foregroundStyle(.secondary)
                    } else if case .saved = filter.sidebarSelection, marks.saved.isEmpty {
                        Text("main.noSavedEntries")
                        Text("main.saveHint").font(.callout).foregroundStyle(.secondary)
                    } else {
                        Text(L10n.string(flowStore.flows.isEmpty ? "main.noCapturedFlows" : "main.noMatchingFlows"))
                        Text(L10n.string(flowStore.flows.isEmpty ? "main.captureHint" : "main.filterHint"))
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .allowsHitTesting(false)
            }
        }
        .contextMenu {
            if let flow = selectedFlow {
                Button("main.mapResponse") {
                    model.mapFlowToMapLocal(flow)
                }
                Divider()
                Button("main.copyURL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(flow.url, forType: .string)
                }
                Menu("main.export") {
                    Button("main.exportCurl") {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(flow.curlCommand, forType: .string)
                    }
                }
            } else {
                Text("main.noFlowSelected")
                    .disabled(true)
            }
        }
    }

    @ViewBuilder
    private func statusCell(_ flow: Flow) -> some View {
        if let error = flow.error, flow.response == nil {
            Text("main.err").font(.caption).foregroundStyle(.red).help(error)
        } else if let status = flow.statusCode {
            Text(verbatim: "\(status)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(Self.statusColor(status))
        } else {
            ProgressView().controlSize(.small)
        }
    }

    @ViewBuilder
    private func detailPane(selectedFlow: Flow?) -> some View {
        if let flow = selectedFlow {
            FlowDetailView(flow: flow)
        } else {
            VStack(spacing: 8) {
                Image(systemName: "arrow.left.arrow.right.circle")
                    .font(.system(size: 34))
                    .foregroundStyle(.tertiary)
                Text("main.selectFlow")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Formatting helpers

    static func methodColor(_ method: String) -> Color {
        switch method.uppercased() {
        case "GET": return .green
        case "POST": return .orange
        case "PUT": return .blue
        case "PATCH": return .purple
        case "DELETE": return .red
        case "HEAD": return .teal
        case "OPTIONS": return .gray
        case "CONNECT": return .pink
        default: return .primary
        }
    }

    static func statusColor(_ status: Int) -> Color {
        switch status {
        case 100..<200: return .secondary
        case 200..<300: return .green
        case 300..<400: return .blue
        case 400..<500: return .orange
        default: return .red
        }
    }

    static func sizeText(_ flow: Flow) -> String {
        let bytes = flow.response?.body.count ?? flow.request.body.count
        return bytes == 0 ? "—" : BodyFormatting.byteCount(bytes)
    }

    static func timeText(_ flow: Flow) -> String {
        guard let total = flow.timing.total else { return "…" }
        if total < 1 { return String(format: "%.0f ms", total * 1000) }
        return String(format: "%.2f s", total)
    }
}

/// The bottom-right balloon that offers a newer release.
///
/// It never downloads or swaps the app: ProxyMaxx is ad-hoc signed and the cask is not
/// notarised, so the swap belongs to Homebrew. An install the cask owns gets "Upgrade Now";
/// anything else gets the command to copy and the release page, because a hand-copied app
/// has no package manager to ask.
struct UpdatePromptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "arrow.down.circle.fill")
                    .foregroundStyle(.blue)
                    .accessibilityHidden(true)
                Text("update.prompt.title")
                    .font(.headline)
                Spacer(minLength: 8)
                Button {
                    model.dismissUpdatePrompt()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("update.prompt.dismissHelp")
                .accessibilityLabel("update.prompt.dismissHelp")
            }

            if let release = model.availableUpdate {
                Text(L10n.format(
                    "update.prompt.message",
                    release.version.description,
                    model.installedVersion?.description ?? "—"
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            }

            commandRow

            if let failure = model.updateUpgradeFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
                    .lineLimit(6)
                    .fixedSize(horizontal: false, vertical: true)
            } else if let message = model.updateCheckMessage {
                Text(message)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            HStack(spacing: 8) {
                Button("update.prompt.releasePage") { model.openReleasePage() }
                    .buttonStyle(.bordered)
                Spacer(minLength: 12)
                if model.canRunUpdate {
                    Button("update.prompt.upgrade") { model.runUpdateUpgrade() }
                        .buttonStyle(.borderedProminent)
                        .fixedSize()
                } else if model.updateUpgradeInFlight {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("update.prompt.upgrading").font(.callout)
                    }
                }
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("update.prompt.title")
    }

    /// The exact command, selectable, with a copy button. Shown for every origin: even an
    /// install the cask owns may fail to upgrade, and this is what it falls back to.
    private var commandRow: some View {
        HStack(spacing: 8) {
            Text(model.updateCommand)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Button("common.copy") {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(model.updateCommand, forType: .string)
            }
            .controlSize(.small)
        }
    }
}

/// The same offer, in Settings, so a dismissed balloon is not the end of the story: the
/// version row and the check button stay available for the user to come back to.
///
/// This pane scrolls rather than growing, so the card keeps one extra line at most: the
/// available version replaces the "installed" line instead of being appended to it.
struct UpdateSettingsCard: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        ToolCard(spacing: 10) {
            HStack(alignment: .center) {
                Text("update.settings.title")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                Spacer(minLength: 8)
                if model.updateCheckInFlight {
                    ProgressView().controlSize(.small)
                } else {
                    Button("update.settings.checkNow") { model.checkForUpdatesManually() }
                        .controlSize(.small)
                }
            }

            if let release = model.availableUpdate {
                Text(L10n.format("update.settings.available", release.version.description))
                    .font(.callout.weight(.semibold))
            } else {
                Text(L10n.format(
                    "update.settings.installed",
                    model.installedVersion?.description ?? L10n.string("update.settings.unbundled")
                ))
                .font(.callout)
                .foregroundStyle(.secondary)
                if let message = model.updateCheckMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }

            if model.installedVersion != nil {
                HStack(spacing: 6) {
                    Text(model.updateCommand)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Button {
                        NSPasteboard.general.clearContents()
                        NSPasteboard.general.setString(model.updateCommand, forType: .string)
                    } label: {
                        Image(systemName: "doc.on.doc")
                    }
                    .buttonStyle(.borderless)
                    .help("common.copy")
                    .accessibilityLabel("common.copy")
                    Spacer(minLength: 0)
                }
                HStack(spacing: 8) {
                    if model.canRunUpdate {
                        Button("update.prompt.upgrade") { model.runUpdateUpgrade() }
                            .controlSize(.small)
                    }
                    if model.availableUpdate != nil {
                        Button("update.prompt.releasePage") { model.openReleasePage() }
                            .controlSize(.small)
                    }
                    Spacer(minLength: 0)
                }
            }

            if let failure = model.updateUpgradeFailure {
                Text(failure)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(4)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The bottom-right balloon that asks about error reporting, once, on the launches where
/// that question is still open.
///
/// The copy is the point of the balloon, so it states what leaves the machine and what does
/// not, and links to the same Privacy information page Settings offers. Every answer is a
/// plain button: nothing is preselected, and closing the balloon with the ✕ only postpones
/// the question to the next launch, so a stray click never becomes a permanent "no".
struct ErrorReportingPromptView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "ladybug.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text("reporting.prompt.title")
                    .font(.headline)
                Spacer(minLength: 8)
                Button {
                    model.dismissErrorReportingPrompt()
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("reporting.prompt.laterHelp")
                .accessibilityLabel("reporting.prompt.laterHelp")
            }
            Text("reporting.prompt.message")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Button("settings.privacyInfo") {
                if let url = URL(string: "https://github.com/AgiMaulana/ProxyMaxx/blob/main/docs/privacy.md") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
            .controlSize(.small)

            // Two quiet answers, one prominent. Enabling starts reporting immediately and
            // moves the Settings switch with it, so the two never disagree.
            HStack(spacing: 8) {
                Button("reporting.prompt.decline") { model.declineErrorReportingPrompt() }
                    .buttonStyle(.bordered)
                Button("reporting.prompt.later") { model.dismissErrorReportingPrompt() }
                    .buttonStyle(.bordered)
                    .help("reporting.prompt.laterHelp")
                Spacer(minLength: 12)
                Button("reporting.prompt.accept") { model.acceptErrorReportingPrompt() }
                    .buttonStyle(.borderedProminent)
                    .fixedSize()
            }
        }
        .padding(16)
        .frame(width: 440, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay {
            RoundedRectangle(cornerRadius: 12).strokeBorder(.quaternary)
        }
        .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("reporting.prompt.title")
    }
}
