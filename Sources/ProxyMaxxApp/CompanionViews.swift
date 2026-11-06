import SwiftUI
import AppKit
import SystemKit

/// Installation artifacts and native host status for the browser companions.
struct BrowserExtensionPanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("browser.panel.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if let path = model.browserExtensionPath {
                    CompanionPathView(path: path)
                }
                hostsLine
                if let check = model.browserBridgeCheck {
                    Text(check)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Text("browser.panel.steps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Text("browser.panel.firefoxSteps")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(18)
        }
        .frame(width: 640)
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack {
            Text("browser.panel.title").font(.title2).bold()
            Spacer()
            Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
    }

    private var hostsLine: some View {
        Group {
            if model.browserExtensionBrowsers.isEmpty {
                Text("browser.panel.noBrowser")
            } else {
                Text(L10n.format(
                    "browser.panel.hosts",
                    model.browserExtensionBrowsers.joined(separator: ", ")
                ))
            }
        }
        .font(.callout)
        .foregroundStyle(.secondary)
        .fixedSize(horizontal: false, vertical: true)
    }
}

struct CommandLineToolPanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var permanently = true
    @State private var manualExpanded = false
    @State private var configured = false
    @State private var copiedPath = false
    @State private var copiedManualCommand = false
    @State private var copiedVerification = false
    @State private var notice: String?
    @State private var errorMessage: String?
    @FocusState private var focusedOption: Bool?

    private let shell = ShellPathExport.detectShell()
    private let verificationCommand = "which proxymaxx-cli"
    private var toolURL: URL { model.commandLineToolURL }
    private var directory: URL { toolURL.resolvingSymlinksInPath().deletingLastPathComponent() }
    private var profileURL: URL { ShellPathExport.profileURL(for: shell) }
    private var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: toolURL.path)
    }

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header
                    location
                    if isInstalled {
                        availability
                        manualSetup
                        verification
                    } else {
                        Label("cli.panel.missing", systemImage: "exclamationmark.triangle")
                            .foregroundStyle(.secondary)
                    }
                    if let notice {
                        Text(notice)
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    if let errorMessage {
                        Label(errorMessage, systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                            .textSelection(.enabled)
                    }
                }
                .padding(28)
            }
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxHeight: 660)
            Divider()
            footer
        }
        .frame(width: 600)
        .background(Color(nsColor: .windowBackgroundColor))
        .onAppear(perform: refreshStatus)
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            refreshStatus()
        }
        .onChange(of: permanently) { _, _ in
            copiedManualCommand = false
            notice = nil
            errorMessage = nil
        }
        .onExitCommand { dismiss() }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: "terminal")
                .font(.system(size: 23, weight: .medium))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(.blue, in: RoundedRectangle(cornerRadius: 12))
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("cli.panel.title")
                        .font(.system(size: 20, weight: .bold))
                    Spacer(minLength: 0)
                    Label {
                        Text(isInstalled
                             ? (configured ? "cli.panel.status.configured" : "cli.panel.status.notConfigured")
                             : "cli.panel.status.missing")
                    } icon: {
                        Image(systemName: configured && isInstalled ? "checkmark.circle.fill" : "circle.fill")
                            .font(.system(size: 7))
                    }
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(configured && isInstalled ? Color.green : Color.orange)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background((configured && isInstalled ? Color.green : Color.orange).opacity(0.12), in: Capsule())
                    .help(L10n.format("cli.panel.status.hint", profileURL.path))
                    .fixedSize()
                }
                Text("cli.panel.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var location: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("cli.panel.location")
            HStack(spacing: 8) {
                Text((toolURL.path as NSString).abbreviatingWithTildeInPath)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(toolURL.path)
                    .accessibilityLabel(toolURL.path)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copiedPath ? "common.copied" : "cli.panel.copyPath") {
                    copy(toolURL.path)
                    copiedPath = true
                }
                Button("cli.panel.reveal") {
                    NSWorkspace.shared.activateFileViewerSelecting([toolURL])
                }
                .disabled(!FileManager.default.fileExists(atPath: toolURL.path))
            }
            .buttonStyle(.bordered)
            .padding(9)
            .background(Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
        }
    }

    private var availability: some View {
        VStack(alignment: .leading, spacing: 10) {
            sectionTitle("cli.panel.export.title")
            option(
                permanent: false,
                title: "cli.panel.export.session",
                hint: L10n.string("cli.panel.export.sessionHint")
            )
            option(
                permanent: true,
                title: "cli.panel.export.permanent",
                hint: L10n.format("cli.panel.export.permanentHint", (profileURL.path as NSString).abbreviatingWithTildeInPath)
            )
            Text(L10n.format("cli.panel.shell", shell.rawValue))
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    private func option(permanent: Bool, title: LocalizedStringKey, hint: String) -> some View {
        let selected = permanently == permanent
        return Button {
            permanently = permanent
        } label: {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: selected ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(selected ? Color.accentColor : Color.secondary)
                    .font(.system(size: 14))
                    .padding(.top, 2)
                    .accessibilityHidden(true)
                VStack(alignment: .leading, spacing: 3) {
                    HStack(spacing: 8) {
                        Text(title).font(.system(size: 14, weight: .semibold))
                        if permanent {
                            Text("cli.panel.recommended")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(Color.accentColor)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 2)
                                .background(Color.accentColor.opacity(0.12), in: Capsule())
                        }
                    }
                    Text(hint)
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(16)
            .background(selected ? Color.accentColor.opacity(0.10) : Color.primary.opacity(0.035), in: RoundedRectangle(cornerRadius: 10))
            .overlay {
                RoundedRectangle(cornerRadius: 10)
                    .strokeBorder(selected ? Color.accentColor : Color.primary.opacity(0.12), lineWidth: selected ? 1.5 : 1)
            }
            .contentShape(RoundedRectangle(cornerRadius: 10))
        }
        .buttonStyle(.plain)
        .focused($focusedOption, equals: permanent)
        .overlay {
            if focusedOption == permanent {
                RoundedRectangle(cornerRadius: 12)
                    .strokeBorder(Color.accentColor, lineWidth: 2)
                    .padding(-3)
            }
        }
        .accessibilityLabel(Text(title))
        .accessibilityValue(Text(selected ? "cli.panel.selected" : "cli.panel.notSelected"))
        .accessibilityHint(hint)
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var manualSetup: some View {
        DisclosureGroup(isExpanded: $manualExpanded) {
            HStack(spacing: 8) {
                Text(manualCommand)
                    .font(.system(.caption, design: .monospaced))
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .textSelection(.enabled)
                    .help(manualCommand)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Button(copiedManualCommand ? "common.copied" : "cli.panel.copyCommand") {
                    copy(manualCommand)
                    copiedManualCommand = true
                }
                .buttonStyle(.bordered)
            }
            .padding(9)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary))
            .padding(.top, 10)
        } label: {
            Text("cli.panel.export.manualTitle")
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .contentShape(Rectangle())
                .onTapGesture { manualExpanded.toggle() }
        }
    }

    private var verification: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("cli.panel.verify.title").font(.headline)
            Text(permanently ? "cli.panel.verify.permanent" : "cli.panel.verify.session")
                .font(.callout)
                .foregroundStyle(.secondary)
            HStack {
                Text(verificationCommand)
                    .font(.system(.callout, design: .monospaced))
                    .foregroundStyle(.green)
                    .textSelection(.enabled)
                Spacer()
                Button(copiedVerification ? "common.copied" : "common.copy") {
                    copy(verificationCommand)
                    copiedVerification = true
                }
                .buttonStyle(.borderless)
                .accessibilityLabel(Text(copiedVerification ? "common.copied" : "cli.panel.verify.copy"))
            }
            .padding(.top, 6)
        }
        .padding(16)
        .background(Color(nsColor: .textBackgroundColor).opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(.quaternary, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
    }

    private var footer: some View {
        HStack(spacing: 10) {
            Button("cli.panel.remove") { removeFromPath() }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
            Spacer()
            Button("common.done") { dismiss() }
                .keyboardShortcut(.cancelAction)
            Button(permanently ? "cli.panel.add" : "cli.panel.openTerminal") {
                if permanently {
                    addToPath()
                } else {
                    openInTerminal()
                }
            }
            .buttonStyle(.borderedProminent)
            .keyboardShortcut(.defaultAction)
            .disabled(!isInstalled)
        }
        .controlSize(.large)
        .padding(.horizontal, 28)
        .padding(.vertical, 16)
    }

    private func sectionTitle(_ title: LocalizedStringKey) -> some View {
        Text(title)
            .font(.caption.weight(.bold))
            .foregroundStyle(.secondary)
    }

    private var manualCommand: String {
        if permanently {
            return "\(ShellPathExport.shellQuoted(toolURL.path, shell: shell)) export"
        }
        return ShellPathExport.exportLine(for: directory.path, shell: shell)
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func refreshStatus() {
        configured = ShellPathExport.isConfigured(directory: directory.path, shell: shell, profileURL: profileURL)
    }

    private func addToPath() {
        errorMessage = nil
        notice = nil
        do {
            _ = try ShellPathExport.install(directory: directory, shell: shell, profileURL: profileURL)
            refreshStatus()
            notice = L10n.format("cli.panel.added", (profileURL.path as NSString).abbreviatingWithTildeInPath)
        } catch {
            errorMessage = L10n.format("cli.panel.updateFailed", error.localizedDescription)
            manualExpanded = true
        }
    }

    private func removeFromPath() {
        errorMessage = nil
        notice = nil
        do {
            let removed = try ShellPathExport.remove(profileURL: profileURL)
            refreshStatus()
            notice = L10n.string(removed ? "cli.panel.removed" : "cli.panel.noManagedBlock")
        } catch {
            errorMessage = L10n.format("cli.panel.updateFailed", error.localizedDescription)
        }
    }

    private func openInTerminal() {
        errorMessage = nil
        notice = nil
        let script = TerminalLauncher.setupScript(directory: directory.path, intent: .thisSessionOnly)
        NSApp.hide(nil)
        TerminalLauncher.open(script: script) { result in
            if case .failure(let error) = result {
                errorMessage = L10n.string("cli.panel.export.failed") + "\n" + error.description
                manualExpanded = true
                NSApp.unhide(nil)
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }
}

/// One machine path with the two actions the panels exist to offer: copy it, or show it in
/// Finder. Shared so the browser and CLI panels cannot drift in how they present a path.
struct CompanionPathView: View {
    let path: String
    @State private var copied = false

    private var exists: Bool {
        FileManager.default.fileExists(atPath: path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("common.path")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
                .contextMenu {
                    Button("companion.copyPath") { copy() }
                    Button("companion.openInFinder") { reveal() }
                        .disabled(!exists)
                }
            HStack {
                Button(copied ? L10n.string("common.copied") : L10n.string("companion.copyPath")) {
                    copy()
                }
                Button("companion.openInFinder") { reveal() }
                    .disabled(!exists)
                Spacer()
            }
        }
    }

    private func copy() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(path, forType: .string)
        copied = true
    }

    private func reveal() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
