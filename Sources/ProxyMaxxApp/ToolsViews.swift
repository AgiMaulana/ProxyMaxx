import SwiftUI
import AppKit
import CertKit
import RuleKit
import SystemKit

// MARK: - SSL Proxying list

struct SSLProxyingView: View {
    @ObservedObject var rules: RuleStore
    var onApply: () -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var newInclude = ""
    @State private var newExclude = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("common.sslProxying").font(.title2).bold()
                Spacer()
                Button("common.done") { onApply(); dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Toggle("ssl.enable", isOn: $rules.isSSLProxyingEnabled)
                .toggleStyle(.switch)
                .padding(.horizontal, 16)

            Text("ssl.intro")
                .font(.caption)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 16)
                .padding(.top, 6)

            HStack(alignment: .top, spacing: 12) {
                patternList(
                    title: "ssl.include",
                    subtitle: rules.includeList.isEmpty ? "ssl.includeEmpty" : nil,
                    patterns: rules.includeList,
                    newValue: $newInclude,
                    onAdd: { rules.addInclude(newInclude); newInclude = ""; onApply() },
                    onRemove: { rules.removeInclude($0); onApply() }
                )
                patternList(
                    title: "ssl.exclude",
                    subtitle: nil,
                    patterns: rules.excludeList,
                    newValue: $newExclude,
                    onAdd: { rules.addExclude(newExclude); newExclude = ""; onApply() },
                    onRemove: { rules.removeExclude($0); onApply() }
                )
            }
            .padding(16)
        }
        .frame(width: 720, height: 460)
    }

    private func patternList(
        title: LocalizedStringKey,
        subtitle: LocalizedStringKey?,
        patterns: [String],
        newValue: Binding<String>,
        onAdd: @escaping () -> Void,
        onRemove: @escaping (String) -> Void
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.headline)
            if let subtitle {
                Text(subtitle).font(.caption).foregroundStyle(.tertiary)
            }
            HStack {
                TextField("ssl.exampleHost", text: newValue)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(onAdd)
                Button("common.add", action: onAdd).disabled(newValue.wrappedValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            List {
                ForEach(patterns, id: \.self) { pattern in
                    HStack {
                        Image(systemName: "globe").foregroundStyle(.secondary)
                        Text(pattern).font(.system(.callout, design: .monospaced))
                        Spacer()
                        Button {
                            onRemove(pattern)
                        } label: {
                            Image(systemName: "minus.circle.fill").foregroundStyle(.red)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .frame(minHeight: 220)
            .border(Color.secondary.opacity(0.2))
        }
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Certificates

/// The Certificate sheet: where the root CA is trusted, exported and explained.
///
/// It is opened from the toolbar, from a refused System Proxy request, and from
/// "Trust certificate" in Settings, so it has to work as a destination: the state and the
/// step that changes it come first, and the details (where trust lands, other devices,
/// manual setup) follow below.
struct CertificatesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 22) {
                    rootCertificateCard
                    trustScopeSection
                    otherDevicesSection
                    if BiometricGate.isAvailable { securitySection }
                    manualSetupSection
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 680, height: 680)
        .onExitCommand { dismiss() }
        .onAppear {
            // Trust can have changed outside the app since the last look.
            model.refreshCertificateTrust()
            model.loadCertificateNameIfNeeded()
        }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 3) {
                Text("cert.title").font(.title2).bold()
                Text("cert.subtitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(20)
    }

    // MARK: Identity and the step that matters

    private var rootCertificateCard: some View {
        ToolCard {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: model.certificateInstalled ? "checkmark.shield.fill" : "exclamationmark.shield.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(model.certificateInstalled ? Color.green : Color.orange)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Text(verbatim: model.certificateCommonName)
                            .font(.headline)
                            .textSelection(.enabled)
                        CertificateStatusChip(trusted: model.certificateInstalled)
                    }
                    Text("cert.intro")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button {
                model.installCertificate()
            } label: {
                Label(
                    model.certificateInstalled ? L10n.string("cert.reinstall") : L10n.string("cert.installAndTrust"),
                    systemImage: "checkmark.shield"
                )
                .frame(maxWidth: .infinity)
                .padding(.vertical, 4)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .padding(.top, 4)
        }
    }

    // MARK: Where it is trusted

    private var trustScopeSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("cert.trustLocation")
            ToolCard(padding: 0) {
                trustScopeRow(
                    symbol: model.certificateInstalled ? "checkmark" : "minus",
                    tint: model.certificateInstalled ? .green : .secondary,
                    title: "cert.scopeUser",
                    detail: "cert.scopeUserDetail"
                )
                Divider().padding(.leading, 54)
                trustScopeRow(
                    symbol: "minus",
                    tint: .secondary,
                    title: "cert.scopeSystem",
                    detail: "cert.scopeSystemDetail"
                )
            }
        }
    }

    private func trustScopeRow(
        symbol: String,
        tint: Color,
        title: LocalizedStringKey,
        detail: LocalizedStringKey
    ) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.callout.weight(.semibold))
                .foregroundStyle(tint)
                .frame(width: 26, height: 26)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 7))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.semibold))
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
    }

    // MARK: Other devices

    /// Both rows use what already exists: the Export CA… save panel, and the Android guide
    /// the toolbar opens. Only the presentation as a list is new.
    private var otherDevicesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("cert.otherDevices")
            ToolCard(padding: 0) {
                ToolRow(symbol: "square.and.arrow.up", title: "cert.export", detail: "cert.exportDetail") {
                    exportCertificate()
                }
                Divider().padding(.leading, 54)
                ToolRow(
                    symbol: "candybarphone",
                    title: "cert.installAndroid",
                    detail: "cert.installAndroidDetail"
                ) {
                    dismiss()
                    model.refreshAndroidDevices()
                    model.showAndroidEmulatorGuide = true
                }
            }
        }
    }

    // MARK: Security

    private var securitySection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("cert.security")
            ToolCard {
                Toggle(isOn: $model.useTouchIDForCertificates) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(L10n.format("cert.confirmChanges", BiometricGate.displayName))
                            .font(.callout.weight(.semibold))
                        Text(L10n.format("cert.confirmChangesDetail", BiometricGate.displayName))
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .toggleStyle(.switch)
                .accessibilityLabel(Text(L10n.format("cert.confirmChanges", BiometricGate.displayName)))
            }
        }
    }

    // MARK: Manual setup

    private var manualSetupSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionHeading("cert.manualSetup")
            ToolCard {
                manualStep(number: "1", title: "cert.pointClient", command: pointClientCommand)
                manualStep(number: "2", title: "cert.trustExported", command: trustExportedCommand)
            }
        }
    }

    private func manualStep(number: String, title: LocalizedStringKey, command: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text(verbatim: number)
                    .font(.caption.weight(.bold).monospacedDigit())
                    .foregroundStyle(.secondary)
                Text(title).font(.callout.weight(.semibold))
            }
            HStack(spacing: 8) {
                Text(verbatim: command)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(command)
                    .frame(maxWidth: .infinity, alignment: .leading)
                CopyTextButton(text: command, accessibilityLabel: L10n.string("common.copy"))
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(.quaternary))
        }
    }

    // MARK: Derived values

    /// The attached engine's port when one owns the proxy, otherwise the saved port.
    private var pointClientCommand: String {
        "curl -x http://127.0.0.1:\(model.activeProxyPort) https://example.com"
    }

    private var trustExportedCommand: String {
        "curl --cacert /path/to/proxymaxx-ca.crt -x http://127.0.0.1:\(model.activeProxyPort) https://example.com"
    }

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private func exportCertificate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymaxx-ca.crt"
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            model.exportCertificate(to: url)
        }
    }
}

// MARK: - Log

struct LogView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("cert.activityLog").font(.title2).bold()
                Spacer()
                Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)
            Divider()
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(model.activityLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(12)
                }
                .onChange(of: model.activityLog.count) { _, count in
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
        .frame(width: 700, height: 440)
    }
}

// MARK: - Settings

/// The Settings pane: proxy state and ports, the certificate's trust at a glance, and error
/// reporting. Each question a user arrives with is answered on the surface (running?
/// trusted? where do these ports point?), with the longer explanation beneath it.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ScrollView {
                HStack(alignment: .top, spacing: 16) {
                    proxyCard
                    VStack(spacing: 16) {
                        certificateCard
                        privacyCard
                        UpdateSettingsCard()
                    }
                    .frame(width: 330)
                }
                .padding(20)
            }
            Divider()
            footer
        }
        // Apple's pane keeps a minimum it enforces, and its size is persisted. Asking for the
        // size the content needs means every row is handed only what it needs: a scroll view
        // otherwise spreads the window's spare height into the cards as empty space. Below
        // about 640pt the pane scrolls instead.
        .frame(width: 820, height: 600)
        .onAppear {
            model.loadCertificateNameIfNeeded()
            model.refreshCertificateTrust()
        }
    }

    // MARK: Proxy

    private var proxyCard: some View {
        ToolCard(spacing: 16) {
            sectionHeading("settings.proxy")
            proxyState
            listenAddressRow
            portFields
            // Ports are applied by the engine when it starts, so the hint appears only
            // while that is true of the current state.
            Text(model.isRunning ? "settings.portsRunningHint" : "settings.portHint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    private var portFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .bottom, spacing: 12) {
                portField(
                    title: "settings.httpPort",
                    value: $model.port,
                    scheme: "http://",
                    help: "settings.httpPortHelp"
                )
                portField(
                    title: "settings.socksPort",
                    value: $model.socksPort,
                    scheme: "socks5://",
                    help: "settings.socksPortHelp"
                )
            }
        }
    }

    /// The state word is the card's headline, because "is it running?" is the question the
    /// pane is usually opened to answer.
    private var proxyState: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(model.isRunning ? Color.green : Color.secondary)
                .frame(width: 10, height: 10)
                .accessibilityHidden(true)
            Text(model.isRunning ? "common.running" : "common.stopped")
                .font(.title2.weight(.semibold))
            if let owner = model.externalOwner {
                Text(owner.owner == .cli ? "settings.servedByCLI" : "settings.servedByAnotherApp")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .accessibilityElement(children: .combine)
    }

    private var listenAddressRow: some View {
        HStack(alignment: .center) {
            VStack(alignment: .leading, spacing: 2) {
                Text("settings.listenAddress")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text(verbatim: "127.0.0.1")
                    .font(.system(.title3, design: .monospaced))
                    .textSelection(.enabled)
            }
            Spacer()
            Label("settings.localOnly", systemImage: "lock")
                .font(.callout)
                .foregroundStyle(.secondary)
                .help(Text("settings.localOnlyHelp"))
        }
        .padding(12)
        .background(.background, in: RoundedRectangle(cornerRadius: 9))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(.quaternary))
    }

    private func portField(
        title: LocalizedStringKey,
        value: Binding<Int>,
        scheme: String,
        help: LocalizedStringKey
    ) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("", value: value, format: .number.grouping(.never))
                .textFieldStyle(.plain)
                .font(.system(.title2, design: .monospaced))
                .multilineTextAlignment(.leading)
                .padding(.horizontal, 12)
                .padding(.vertical, 8)
                .background(.background, in: RoundedRectangle(cornerRadius: 9))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Color(nsColor: .separatorColor)))
                .disabled(model.isRunning)
                .accessibilityLabel(Text(title))
                .help(Text(help))
            Text(verbatim: "\(scheme)127.0.0.1:\(value.wrappedValue)")
                .font(.system(.caption, design: .monospaced))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .textSelection(.enabled)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: Certificate

    /// A summary, not a control surface: the state, the name, and one way forward. The
    /// button opens the Certificate sheet on the main window, so the trust step is taken
    /// where its explanation, Android steps and manual setup live.
    private var certificateCard: some View {
        ToolCard(spacing: 12) {
            HStack {
                sectionHeading("settings.certificate")
                Spacer()
                CertificateStatusChip(trusted: model.certificateInstalled)
            }
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "checkmark.shield")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 2) {
                    Text("settings.commonName")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(verbatim: model.certificateCommonName)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer(minLength: 0)
            }
            Button(action: openCertificateSheet) {
                HStack {
                    Text(model.certificateInstalled ? "settings.reviewCertificate" : "settings.trustCertificate")
                        .fontWeight(.semibold)
                    Spacer()
                    Image(systemName: "arrow.right")
                }
                .padding(.vertical, 2)
            }
            .buttonStyle(.bordered)
            .tint(.orange)
            .controlSize(.large)
            Text("settings.opensCertificateSheet")
                .font(.caption)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity)
                .multilineTextAlignment(.center)
        }
    }

    private func openCertificateSheet() {
        // Presented by the main window: the sheet belongs to the proxy's state, not to this
        // pane, and it must be the same sheet the toolbar and the trust banner open.
        NSApp.activate(ignoringOtherApps: true)
        for window in NSApp.windows where window.canBecomeKey && window.title == "ProxyMaxx" {
            window.makeKeyAndOrderFront(nil)
            break
        }
        model.showCertificateSheet = true
    }

    // MARK: Privacy

    private var privacyCard: some View {
        ToolCard(spacing: 12) {
            sectionHeading("settings.privacy")
            Toggle(isOn: $model.errorReportingEnabled) {
                Text("settings.errorReporting")
                    .font(.callout.weight(.semibold))
            }
            .toggleStyle(.switch)
            .disabled(!model.isCrashReportingAvailable)
            Text("settings.errorReportingHint")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            SpanChips()
            if !model.isCrashReportingAvailable {
                Text("settings.errorReportingUnavailable")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if model.errorReportingDeclinedAtLaunch {
                Text("settings.errorReportingAsked")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("settings.privacyInfo") {
                if let url = URL(string: "https://github.com/AgiMaulana/ProxyMaxx/blob/main/docs/privacy.md") {
                    NSWorkspace.shared.open(url)
                }
            }
            .buttonStyle(.link)
        }
    }

    // MARK: Chrome

    private func sectionHeading(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .textCase(.uppercase)
    }

    private var footer: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Text(verbatim: "ProxyMaxx")
                .font(.footnote.weight(.semibold))
            Text("settings.aboutText")
                .font(.footnote)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 10)
    }
}
