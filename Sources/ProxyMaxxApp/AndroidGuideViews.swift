import SwiftUI
import AppKit
import SystemKit

/// The Android Emulator setup guide.
///
/// One path, top to bottom: choose a target, choose a root method, install. Step 3 stays grey
/// until a target exists, so the order is visible rather than something to infer. The output
/// panel is always present: the six steps report, the installer's lines are the record.
struct AndroidEmulatorGuideView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            GuideHeader { dismiss() }
            ScrollView {
                VStack(spacing: 16) {
                    TargetCard(active: true)
                    RootCard(active: hasTarget || model.androidMode == .manual)
                    InstallCard(active: hasTarget || model.androidMode == .manual)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 20)
            }
            InstallOutput()
                .padding(.horizontal, 24)
                .padding(.bottom, model.androidShowsOutput ? 20 : 16)
        }
        .frame(minWidth: 640, idealWidth: 760, maxWidth: .infinity,
               minHeight: 560, idealHeight: 780, maxHeight: .infinity)
        .onAppear { model.refreshAndroidDevices() }
    }

    private var hasTarget: Bool { model.androidSelectedDevice != nil }
}

// MARK: - Header

private struct GuideHeader: View {
    let done: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            VStack(alignment: .leading, spacing: 4) {
                Text("android.emulator.title")
                    .font(.system(size: 20, weight: .bold))
                Text("android.emulator.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button("common.done", action: done)
                .controlSize(.large)
                .keyboardShortcut(.cancelAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 16)
        .background { ZStack(alignment: .bottom) { Rectangle().fill(.bar); Divider() } }
    }
}

// MARK: - 1. Choose a target

private struct TargetCard: View {
    @EnvironmentObject var model: AppModel
    let active: Bool

    var body: some View {
        StepCard(number: 1, title: "android.emulator.step.target", active: active) {
            if model.androidDevices.isEmpty {
                noDeviceRow
            } else {
                DevicePickerList()
            }

            if let note = imageNote {
                Notice(tone: .warning, text: note)
            }

            if let error = model.androidError, !model.androidBusy, !model.androidFinished {
                Notice(tone: .failure, text: error)
            }

            Toggle("android.emulator.includePhysical", isOn: $model.androidIncludePhysical)
                .toggleStyle(.checkbox)
                .help("android.emulator.includePhysicalHelp")

            proxyFields

            if AndroidToolchain.adbPath() == nil {
                Label("android.emulator.adbMissing", systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            if AndroidResources.tunnelAPK() == nil {
                Label("android.emulator.apkMissing", systemImage: "info.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The empty state is the refresh control: with nothing to pick, the row says what to
    /// start and the only thing to do about it.
    private var noDeviceRow: some View {
        HStack(spacing: 12) {
            Image(systemName: "iphone.slash")
                .font(.system(size: 22))
                .foregroundStyle(.orange)
                .frame(width: 36)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 2) {
                Text("android.emulator.noDevice.title")
                    .font(.callout.weight(.semibold))
                Text("android.emulator.noDevice.detail")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            Button("common.refresh") { model.refreshAndroidDevices() }
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
        }
        .padding(12)
        .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [4, 3]))
        )
        .accessibilityElement(children: .contain)
    }

    /// A physical device needs a security setting changed before `adb root` can work. A Play
    /// image cannot say so from here, so the installer reports it once it runs.
    private var imageNote: String? {
        guard let device = model.androidSelectedDevice else { return nil }
        if !device.isEmulator {
            return L10n.string("android.emulator.physicalADBNote")
        }
        return nil
    }

    private var proxyFields: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 10) {
                ValueField(label: "android.emulator.httpProxy", value: proxyAddress(http: true))
                ValueField(label: "android.emulator.socks5", value: proxyAddress(http: false))
            }
            Text("android.emulator.hostNote")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func proxyAddress(http: Bool) -> String {
        let port = http ? model.port : model.boundSocksPort ?? model.socksPort
        return "\(model.androidHostAddress):\(port)"
    }
}

// MARK: - 2. How to get root access

private struct RootCard: View {
    @EnvironmentObject var model: AppModel
    let active: Bool

    var body: some View {
        StepCard(number: 2, title: "android.emulator.step.root", active: active) {
            ModeSegments(selection: $model.androidMode)

            Text(model.androidMode.explanation)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if showsMagisk {
                Divider()
                magiskSection
            }
        }
    }

    private var showsMagisk: Bool {
        model.androidMode != .googleAPIs && model.androidMode != .manual && model.androidMode != .revert
    }

    private var magiskSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Toggle(isOn: $model.androidEnableMagisk) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("android.emulator.magiskToggle")
                        .font(.callout.weight(.semibold))
                    Text("android.emulator.magiskIntro")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .toggleStyle(.switch)
            .controlSize(.large)

            factRows
                .opacity(model.androidEnableMagisk ? 1 : 0.55)
        }
    }

    /// A grid keeps the three facts the same height, which is what makes them read as one
    /// statement in three parts rather than three loose cards.
    private var factRows: some View {
        Grid(horizontalSpacing: 10, verticalSpacing: 10) {
            GridRow(alignment: .top) {
                MagiskFact(tone: .green, title: "android.emulator.magisk.what",
                           detail: "android.emulator.magisk.whatBody")
                MagiskFact(tone: .blue, title: "android.emulator.magisk.untouched",
                           detail: "android.emulator.magisk.untouchedBody")
                MagiskFact(tone: .orange, title: "android.emulator.magisk.headsUp",
                           detail: "android.emulator.magisk.headsUpBody")
            }
        }
    }
}

// MARK: - 3. Install

private struct InstallCard: View {
    @EnvironmentObject var model: AppModel
    let active: Bool
    @State private var showManualCommand = false

    var body: some View {
        StepCard(number: 3, title: "android.emulator.step.install", active: active) {
            if model.androidFinished, model.androidError == nil {
                Notice(tone: .success, text: L10n.string("android.emulator.installed"))
            } else if model.androidError != nil, !model.androidBusy {
                Notice(tone: .failure, text: model.androidError ?? "")
            }

            actions

            Text(hint)
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            if model.androidMode == .manual || showManualCommand || model.androidCommandPreview() == nil {
                ManualCommandSection()
            }
        }
    }

    /// Says what is missing whenever a control is disabled, which is the whole reason the row
    /// has a hint line rather than only a button state.
    private var hint: String {
        if model.androidBusy { return L10n.string("android.emulator.keepStudioOpen") }
        if model.androidFinished, model.androidError == nil {
            return L10n.string("android.emulator.connectedHint")
        }
        if model.androidError != nil { return L10n.string("android.emulator.output.hint") }
        if model.androidMode == .manual { return L10n.string("android.emulator.manualStatus") }
        if !hasTarget { return L10n.string("android.emulator.connectFirst") }
        return L10n.string("android.emulator.ready")
    }

    private var hasTarget: Bool { model.androidSelectedDevice != nil }

    private var canInstall: Bool {
        guard !model.androidBusy else { return false }
        return model.androidMode == .manual || hasTarget
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                model.installCertificateOnAndroid()
            } label: {
                Text(model.androidMode == .manual
                     ? "android.emulator.showCommand"
                     : model.androidBusy ? "android.emulator.installing" : "android.emulator.installCta")
                    .frame(minWidth: 110)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .disabled(!canInstall)

            Button("android.emulator.revertAll") { model.revertAndroidChanges() }
                .controlSize(.large)
                .disabled(model.androidBusy)

            if model.androidMode != .manual {
                Button {
                    showManualCommand.toggle()
                } label: {
                    Text(showManualCommand
                         ? "android.emulator.hideCommand"
                         : "android.emulator.showCommand")
                }
                .accessibilityLabel(Text(L10n.string(showManualCommand
                    ? "android.emulator.hideCommand"
                    : "android.emulator.showCommand")))
                    .buttonStyle(.link)
                    .controlSize(.large)
            }

            Spacer(minLength: 0)
        }
    }
}

// MARK: - Manual command and log

/// Manual mode shows the exact command, and so does Show Command. The command depends on the
/// mode, so the button that opens it is hidden in manual mode, where it is always shown.
private struct ManualCommandSection: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("android.emulator.manualHint")
                .font(.caption)
                .foregroundStyle(.secondary)

            if let command = model.androidCommandPreview() {
                HStack(alignment: .top, spacing: 8) {
                    Text(command)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .padding(8)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                    CopyTextButton(text: command, accessibilityLabel: L10n.string("android.emulator.copyCommand"))
                }
            } else {
                Text("android.emulator.resourcesMissing")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
        }
    }
}
