import SwiftUI
import FlowKit
import RuleKit
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
        .onAppear {
            model.refreshExternalOwner()
            model.refreshSystemProxyState()
            model.detectStaleSystemProxy()
            model.applyCommandLineOptions()
            model.beginExternalOwnerWatch()
        }
    }

    private func sidebarView(summary: FlowSummary) -> some View {
        List {
            Section("main.favorites") {
                sidebarRow(L10n.string("main.all"), systemImage: "tray", selection: .all, count: summary.total)
                sidebarRow(L10n.string("main.pinned"), systemImage: "pin", selection: .pinned, count: summary.pinned)
                sidebarRow(L10n.string("main.saved"), systemImage: "bookmark", selection: .saved, count: summary.saved)
            }

            if !summary.apps.isEmpty {
                Section(header: Text(L10n.format("main.apps", summary.apps.count))) {
                    ForEach(summary.apps, id: \.self) { app in
                        sidebarRow(app, systemImage: "app.badge", selection: .app(app), count: summary.appCount(app))
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

    private func sidebarRow(_ title: String, systemImage: String, selection: SidebarSelection, count: Int) -> some View {
        Button {
            filter.sidebarSelection = selection
        } label: {
            HStack {
                Label(title, systemImage: systemImage)
                Spacer()
                Text(verbatim: "\(count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .listRowBackground(filter.sidebarSelection == selection ? Color.accentColor.opacity(0.18) : Color.clear)
    }

    /// One-pass roll-up of the captured flows for the sidebar.
    ///
    /// The sidebar needs per-app and per-domain counts plus the sorted key lists.
    /// Recomputing each count by re-filtering every flow once per row is
    /// O(flows × domains); folding it all into a single pass keeps the sidebar cheap
    /// as a session grows toward `FlowStore.maxFlows`.
    private struct FlowSummary {
        let total: Int
        let pinned: Int
        let saved: Int
        let apps: [String]
        let domains: [String]
        private let appCounts: [String: Int]
        private let domainCounts: [String: Int]

        init(_ flows: [Flow]) {
            var pinned = 0
            var saved = 0
            var appCounts: [String: Int] = [:]
            var domainCounts: [String: Int] = [:]
            for flow in flows {
                if flow.isPinned { pinned += 1 }
                if flow.response != nil { saved += 1 }
                if let app = flow.clientApp { appCounts[app, default: 0] += 1 }
                domainCounts[flow.host, default: 0] += 1
            }
            self.total = flows.count
            self.pinned = pinned
            self.saved = saved
            self.appCounts = appCounts
            self.domainCounts = domainCounts
            self.apps = appCounts.keys.sorted()
            self.domains = domainCounts.keys.sorted()
        }

        func appCount(_ app: String) -> Int { appCounts[app] ?? 0 }
        func domainCount(_ domain: String) -> Int { domainCounts[domain] ?? 0 }
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
                .disabled(flows.isEmpty)
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
                Text(flow.clientApp ?? "—")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            .width(90)
        }
        .tableStyle(.inset(alternatesRowBackgrounds: true))
        .contextMenu {
            if let flow = selectedFlow {
                Button("main.mapResponse") {
                    mapFlowToMapLocal(flow)
                }
                Divider()
                Button("main.copyURL") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(flow.url, forType: .string)
                }
                Button("main.copyAsCurl") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(flow.curlCommand, forType: .string)
                }
            } else {
                Text("main.noFlowSelected")
                    .disabled(true)
            }
        }
    }

    private func mapFlowToMapLocal(_ flow: Flow) {
        let filePath = MapLocalView.generateDefaultFile()

        // Write the body decoded so the file is editable; the Content-Encoding header
        // then describes bytes that are no longer there, so it is dropped with it.
        let decodedBody = flow.response.flatMap { ContentDecoding.decode($0.body, encoding: $0.contentEncoding) }

        var content = "HTTP/1.1 \(flow.statusCode ?? 200) OK\r\n"
        if let response = flow.response {
            for header in response.headers.entries {
                if decodedBody != nil, header.name.caseInsensitiveCompare("Content-Encoding") == .orderedSame { continue }
                content += "\(header.name): \(header.value)\r\n"
            }
        }
        content += "\r\n"
        let body = decodedBody ?? flow.response?.body ?? Data()
        if !body.isEmpty {
            if let prettyJSON = BodyFormatting.prettyJSON(body) {
                content += prettyJSON
            } else if let bodyStr = String(data: body, encoding: .utf8) {
                content += bodyStr
            }
        }
        
        try? content.write(toFile: filePath, atomically: true, encoding: .utf8)
        
        let parsedURL = URL(string: flow.url)
        let cleanedURL = flow.url
            .replacingOccurrences(of: "https://", with: "")
            .replacingOccurrences(of: "http://", with: "")
        
        let path = parsedURL?.path ?? ""
        let host = parsedURL?.host ?? ""
        let ruleName = path.isEmpty || path == "/" ? host : path
        
        let rule = MapLocalRule(
            name: ruleName.isEmpty ? cleanedURL : ruleName,
            url: cleanedURL,
            matchStyle: .wildcard,
            includePath: true,
            destination: .file(filePath)
        )
        
        model.ruleStore.addMapLocalRule(rule)
        model.applyRules()
        model.showMapLocalWindow = true
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
