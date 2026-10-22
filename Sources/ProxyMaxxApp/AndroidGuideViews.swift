import SwiftUI
import AppKit
import SystemKit

/// The Android Emulator setup guide.
///
/// One window, an advanced mode picker, an explicit Magisk consent, and the script's own
/// output shown while it runs.
struct AndroidEmulatorGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showManualCommand = false

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    introduction
                    deviceSection
                    modeSection
                    if model.androidMode != .googleAPIs, model.androidMode != .manual, model.androidMode != .revert {
                        magiskSection
                    }
                    if let error = model.androidError {
                        errorNotice(error)
                    }
                    actions
                    if model.androidMode == .manual || showManualCommand {
                        manualCommandSection
                    }
                    logSection
                }
                .padding(18)
            }
        }
        .frame(width: 760, height: 640)
        .onAppear { model.refreshAndroidDevices() }
    }

    private var header: some View {
        HStack {
            Text("android.emulator.title").font(.title2).bold()
            Spacer()
            Button("common.refresh") { model.refreshAndroidDevices() }
            Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var introduction: some View {
        Text("android.emulator.intro")
            .font(.callout)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
    }

    private var deviceSection: some View {
        GroupBox("android.emulator.target") {
            VStack(alignment: .leading, spacing: 8) {
                if model.androidDevices.isEmpty {
                    Label("android.emulator.noDevice", systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                } else {
                    Picker("android.emulator.device", selection: $model.androidSerial) {
                        ForEach(model.androidDevices) { device in
                            Text(device.displayName).tag(Optional(device.serial))
                        }
                    }
                    .frame(maxWidth: 460)
                }

                Toggle("android.emulator.includePhysical", isOn: $model.androidIncludePhysical)
                    .toggleStyle(.checkbox)
                    .help("android.emulator.includePhysicalHelp")

                LabeledContent("android.emulator.proxyAddress") {
                    Text(L10n.format(
                        "android.emulator.proxyAddressValue",
                        model.androidHostAddress,
                        model.port,
                        model.boundSocksPort ?? model.socksPort
                    ))
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                }

                if AndroidToolchain.adbPath() == nil {
                    Label("android.emulator.adbMissing", systemImage: "xmark.octagon")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
                if AndroidResources.tunnelAPK() == nil {
                    Label("android.emulator.apkMissing", systemImage: "info.circle")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var modeSection: some View {
        GroupBox("android.emulator.advancedMode") {
            VStack(alignment: .leading, spacing: 8) {
                Picker("", selection: $model.androidMode) {
                    ForEach(AndroidInstallMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 320)

                Text(model.androidMode.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var magiskSection: some View {
        GroupBox("android.emulator.playAVDs") {
            VStack(alignment: .leading, spacing: 8) {
                Toggle("android.emulator.magiskToggle", isOn: $model.androidEnableMagisk)
                    .toggleStyle(.switch)

                Text("android.emulator.magiskIntro")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)

                Text("android.emulator.magiskConsent")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Shown next to the button that caused it. The guide is a sheet, so an app-level alert
    /// would be swallowed until the sheet closed, which looked like Install did nothing.
    private func errorNotice(_ message: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .accessibilityHidden(true)
            Text(message)
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
                .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(nsColor: .controlBackgroundColor))
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.installCertificateOnAndroid()
            } label: {
                Label(model.androidMode == .revert ? L10n.string("android.emulator.revert") : L10n.string("android.emulator.install"), systemImage: model.androidMode == .revert ? "arrow.uturn.backward" : "lock.shield")
            }
            .buttonStyle(.borderedProminent)
            .disabled(model.androidBusy || (model.androidDevices.isEmpty && model.androidMode != .manual))

            Button {
                model.revertAndroidChanges()
            } label: {
                Label("android.emulator.revertAll", systemImage: "arrow.uturn.backward")
            }
            .disabled(model.androidBusy)

            Button("android.emulator.showCommand") { showManualCommand.toggle() }
                .disabled(model.androidMode == .manual)

            Spacer()

            if model.androidBusy {
                ProgressView().controlSize(.small)
            } else {
                Label("android.emulator.noAdminPrompt", systemImage: "lock.open")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var manualCommandSection: some View {
        GroupBox("android.emulator.manualTitle") {
            VStack(alignment: .leading, spacing: 8) {
                Text("android.emulator.manualHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)

                if let command = model.androidCommandPreview() {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor))
                        .clipShape(RoundedRectangle(cornerRadius: 5))

                    HStack {
                        Button("common.copy") {
                            NSPasteboard.general.clearContents()
                            NSPasteboard.general.setString(command, forType: .string)
                        }
                        Spacer()
                    }
                } else {
                    Text("android.emulator.resourcesMissing")
                        .font(.caption)
                        .foregroundStyle(.red)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var logSection: some View {
        GroupBox("android.emulator.output") {
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 2) {
                        if model.androidLog.isEmpty {
                            Text("android.emulator.noOutput")
                                .font(.system(.caption, design: .monospaced))
                                .foregroundStyle(.tertiary)
                        }
                        ForEach(Array(model.androidLog.enumerated()), id: \.offset) { index, line in
                            Text(line)
                                .font(.system(.caption, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .id(index)
                        }
                    }
                    .padding(8)
                }
                .frame(height: 190)
                .onChange(of: model.androidLog.count) { _, count in
                    guard count > 0 else { return }
                    proxy.scrollTo(count - 1, anchor: .bottom)
                }
            }
        }
    }
}

/// The physical-device guide. Informational: it states the two manual steps, because a real
/// device's trust store is the user's to change.
struct AndroidDeviceGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("android.device.title").font(.title2).bold()
                Spacer()
                Button("cert.export") { exportCA() }
                Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding(16)

            Divider()

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    Text("android.device.intro")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    GroupBox("android.device.step1") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("android.device.step1Hint")
                                .font(.callout)
                            code("\(AndroidToolchain.lanIPv4Address() ?? L10n.string("android.device.lanPlaceholder")):\(model.port)")
                            Text("android.device.step1Instructions")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                            if AndroidToolchain.lanIPv4Address() == nil {
                                Label("android.device.noLAN", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    GroupBox("android.device.step2") {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("android.device.step2Body")
                                .font(.callout)
                                .fixedSize(horizontal: false, vertical: true)
                            Text("android.device.rootNote")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                        .padding(6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Text("android.device.summary")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(18)
            }
        }
        .frame(width: 640, height: 560)
    }

    private func exportCA() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymaxx-ca.crt"
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            model.exportCertificate(to: url)
        }
    }

    private func code(_ text: String) -> some View {
        Text(text)
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }
}
