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
    @State private var filter = FlowFilter()
    @State private var selection: UUID?
    @State private var showSSLProxying = false
    @State private var showCertificates = false
    @State private var showLog = false
    /// Set when capture emptied the table and left a device selection whose emulator stopped.
    @State private var deviceGone = false

    var body: some View {
        // Derived once per pass. `flows` was a computed property read five times, each
        // read re-filtering the whole store.
        let flows = filter.apply(to: flowStore.flows)
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
        .sheet(isPresented: $showCertificates) { CertificatesView().environmentObject(model) }
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
        }
    }

    private func sidebarView(summary: FlowSummary) -> some View {
        List(selection: sidebarSelection) {
            Section("main.favorites") {
                sidebarRow(L10n.string("main.all"), systemImage: "tray", selection: .all, count: summary.total)
                sidebarRow(L10n.string("main.pinned"), systemImage: "pin", selection: .pinned, count: summary.pinned)
                sidebarRow(L10n.string("main.saved"), systemImage: "bookmark", selection: .saved, count: summary.saved)
            }

            if !model.connectedDevices.isEmpty {
                let counts = DeviceFlowCounts(flowStore.flows)
                Section(header: Text(L10n.format("main.devices", model.connectedDevices.count))) {
                    ForEach(model.connectedDevices) { device in
                        deviceRow(device, count: counts.count(for: device.serial))
                    }
                }
            }

            if !summary.apps.isEmpty {
                Section(header: Text(L10n.format("main.apps", summary.apps.count))) {
                    ForEach(summary.apps) { entry in
                        HStack {
                            ClientAppLabel(app: entry.app, showsIdentity: summary.duplicateAppNames.contains(entry.app.name))
                            Spacer()
                            sidebarCount(entry.count)
                        }
                        .tag(SidebarSelection.client(entry.id))
                    }
                }
            }

            Section(header: Text(L10n.format("main.domains", summary.domains.count))) {
                ForEach(summary.domains, id: \.self) { domain in
                    sidebarRow(domain, systemImage: "globe", selection: .domain(domain), count: summary.domainCount(domain))
                }
            }
        }
        .listStyle(.sidebar)
        .frame(minWidth: 200, idealWidth: 240, maxWidth: 300)
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

    /// One connected device. The Help view explains the shared emulator address, so it sits
    /// on the icon alone: inside the Label it swallowed the click before the row could be
    /// selected, because the tooltip view takes hover input across the whole row.
    private func deviceRow(_ device: AndroidDevice, count: Int) -> some View {
        HStack {
            Label {
                Text(L10n.string(device.displayName)).lineLimit(1)
            } icon: {
                Image(systemName: device.isEmulator ? "android" : "candybarphone")
                    .help(L10n.string("main.devicesHelp"))
            }
            Spacer()
            sidebarCount(count)
        }
        .contentShape(Rectangle())
        .tag(SidebarSelection.device(device.serial))
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
        let pinned: Int
        let saved: Int
        let apps: [AppSummary]
        let duplicateAppNames: Set<String>
        let domains: [String]
        private let domainCounts: [String: Int]

        init(_ flows: [Flow]) {
            var pinned = 0
            var saved = 0
            var apps: [String: AppSummary] = [:]
            var domainCounts: [String: Int] = [:]
            for flow in flows {
                if flow.isPinned { pinned += 1 }
                if flow.response != nil || flow.error != nil { saved += 1 }
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
            self.pinned = pinned
            self.saved = saved
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
            Button { showCertificates = true } label: { Label("common.certificates", systemImage: "checkmark.seal") }
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
            Button("main.trustCertificateAction") { showCertificates = true }
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
