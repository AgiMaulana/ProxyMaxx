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

struct CertificatesView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    /// Shared width of the label column, so the certificate values line up.
    private let labelWidth: CGFloat = 112

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    rootCertificateSection
                    actionRow
                    if BiometricGate.isAvailable { biometricToggle }
                    trustSection
                    manualSetupSection
                }
                .padding(18)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 700, height: 620)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack {
            Text("common.certificates").font(.title2).bold()
            Spacer()
            Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(18)
    }

    private var rootCertificateSection: some View {
        card("cert.root") {
            VStack(alignment: .leading, spacing: 10) {
                row("cert.commonName", model.certificateCommonName)
                row("common.trusted", model.certificateInstalled ? L10n.string("cert.trustedUser") : L10n.string("common.no"))
                Text("cert.intro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var actionRow: some View {
        HStack(spacing: 8) {
            Button {
                model.installCertificate()
            } label: {
                Label(model.certificateInstalled ? L10n.string("cert.reinstall") : L10n.string("cert.installAndTrust"), systemImage: "lock.shield")
            }
            .buttonStyle(.borderedProminent)

            Button {
                exportCertificate()
            } label: {
                Label("cert.export", systemImage: "square.and.arrow.up")
            }

            Button {
                dismiss()
                model.refreshAndroidDevices()
                model.showAndroidEmulatorGuide = true
            } label: {
                Label("cert.installAndroid", systemImage: "candybarphone")
            }

            Spacer(minLength: 0)
        }
    }

    private var biometricToggle: some View {
        Toggle(
            L10n.format("cert.authoriseWith", BiometricGate.displayName),
            isOn: $model.useTouchIDForCertificates
        )
        .toggleStyle(.switch)
        .help(Text(verbatim: L10n.format("cert.biometricHelp", BiometricGate.displayName)))
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var trustSection: some View {
        card("cert.trustLocation") {
            VStack(alignment: .leading, spacing: 8) {
                Text("cert.trustedUserHelp")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Text("cert.machineWideHelp")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var manualSetupSection: some View {
        card("cert.manualSetup") {
            VStack(alignment: .leading, spacing: 8) {
                Text("cert.pointClient").font(.callout)
                code("curl -x http://127.0.0.1:\(model.port) https://example.com")
                Text("cert.trustExported")
                    .font(.callout)
                    .padding(.top, 6)
                code("curl --cacert /path/to/proxymaxx-ca.crt -x http://127.0.0.1:\(model.port) https://example.com")
            }
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Native `GroupBox` label; the extra bottom padding widens AppKit's ~4pt
    /// label-to-card gap to 10pt without taking the title out of the box.
    private func card<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        GroupBox {
            content()
        } label: {
            Text(title)
                .font(.caption.weight(.semibold))
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func exportCertificate() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymaxx-ca.crt"
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            model.exportCertificate(to: url)
        }
    }

    private func row(_ title: LocalizedStringKey, _ value: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            Text(value)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.caption, design: .monospaced))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
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

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    /// Shared width of the label column, so values line up down the pane.
    private let labelWidth: CGFloat = 116

    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            section("settings.proxy") {
                row("settings.listenAddress") {
                    Text("127.0.0.1")
                        .font(.system(.callout, design: .monospaced))
                }
                row("settings.httpPort") {
                    portField("9090", value: $model.port)
                        .accessibilityLabel("settings.httpPort")
                }
                row("settings.socksPort") {
                    portField("8989", value: $model.socksPort)
                        .accessibilityLabel("settings.socksPort")
                }
                row("common.status") {
                    HStack(spacing: 6) {
                        Circle()
                            .fill(model.isRunning ? Color.green : Color.secondary)
                            .frame(width: 8, height: 8)
                            .accessibilityHidden(true)
                        Text(model.isRunning ? L10n.string("common.running") : L10n.string("common.stopped"))
                            .font(.callout)
                    }
                }
                Text("settings.portHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.top, 2)
            }
            section("settings.certificate") {
                row("settings.commonName") {
                    Text(model.certificateCommonName)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                }
                row("common.trusted") {
                    Text(model.certificateInstalled ? L10n.string("common.yes") : L10n.string("common.no"))
                        .font(.callout)
                }
            }
            section("settings.about") {
                Text(ProxyMaxxAbout.summary)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(24)
        .frame(width: 520, alignment: .leading)
    }

    private func section<Content: View>(_ title: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(title).font(.headline)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func row<Content: View>(_ label: LocalizedStringKey, @ViewBuilder content: () -> Content) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 16) {
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: labelWidth, alignment: .leading)
            content()
            Spacer(minLength: 0)
        }
    }

    private func portField(_ placeholder: String, value: Binding<Int>) -> some View {
        TextField(placeholder, value: value, format: .number.grouping(.never))
            .textFieldStyle(.roundedBorder)
            .monospacedDigit()
            .multilineTextAlignment(.trailing)
            .frame(width: 84)
            .disabled(model.isRunning)
    }
}
