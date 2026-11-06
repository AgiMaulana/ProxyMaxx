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

/// The bundled CLI and where to find it.
struct CommandLineToolPanelView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var launchFailed = false
    @State private var copiedManualCommand = false

    private var toolURL: URL { model.commandLineToolURL }
    private var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: toolURL.path)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 16) {
                Text("cli.panel.intro")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                CompanionPathView(path: toolURL.path)
                Text("cli.panel.note")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if isInstalled {
                    pathExportSection
                } else {
                    Text("cli.panel.missing")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(18)
        }
        .frame(width: 640)
        .onExitCommand { dismiss() }
    }

    /// The `export` half of the panel: two buttons and the command they stand in for.
    ///
    /// The two buttons are separate because they answer different questions — "use it now,
    /// here" versus "use it from now on, everywhere" — and a terminal the user already has
    /// open cannot be reached from here anyway, so a terminal they can copy the command into
    /// has to stay on screen. A terminal opened by the first button also starts a shell after
    /// the export, because Terminal closes a window as soon as its command exits.
    private var pathExportSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("cli.panel.export.title").font(.headline)
            Text("cli.panel.export.intro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("cli.panel.export.session") {
                        openInTerminal(.thisSessionOnly)
                    }
                    Spacer()
                }
                Text("cli.panel.export.sessionHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Button("cli.panel.export.permanent") {
                        openInTerminal(.permanently)
                    }
                    Spacer()
                }
                Text("cli.panel.export.permanentHint")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            // The fallback for a machine where neither button can reach Terminal: the bare
            // command, copyable in one click. It writes the same block the second button
            // does, so it is the permanent form rather than a third meaning.
            Text("cli.panel.export.manualTitle")
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            HStack(spacing: 8) {
                Text(manualCommand)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color(nsColor: .textBackgroundColor))
                    .clipShape(RoundedRectangle(cornerRadius: 5))
                Button(copiedManualCommand ? L10n.string("common.copied") : L10n.string("companion.copyCommand")) {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(manualCommand, forType: .string)
                    copiedManualCommand = true
                }
            }

            if launchFailed {
                Text("cli.panel.export.failed")
                    .font(.caption)
                    .foregroundStyle(.red)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// The command shown under the buttons: bare `export`, matching what the second button
    /// runs, so a user who copies it gets the same result without having to decode a flag.
    private var manualCommand: String {
        "\(quoted(toolURL.path)) export"
    }

    private func quoted(_ path: String) -> String {
        guard path.contains(" ") || path.contains("'") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Open a window that does what `intent` asks. `launchFailed` drives the red line under
    /// the buttons; the copyable command below them is the fallback either way.
    private func openInTerminal(_ intent: TerminalLauncher.Intent) {
        let script = TerminalLauncher.setupScript(
            directory: toolURL.deletingLastPathComponent().path,
            intent: intent
        )
        launchFailed = false
        // The window belongs to Terminal, so the app steps aside instead of competing for
        // focus with the thing the user just asked to see.
        NSApp.hide(nil)
        TerminalLauncher.open(script: script) { result in
            if case .failure(let error) = result {
                launchFailed = true
                // The alert is the only place the reason survives: the red line under the
                // button says what happened, and this says why, which a bug report needs.
                let alert = NSAlert()
                alert.messageText = L10n.string("cli.panel.export.failed")
                alert.informativeText = error.description
                alert.alertStyle = .warning
                alert.runModal()
                NSApp.activate(ignoringOtherApps: true)
            }
        }
    }

    private var header: some View {
        HStack {
            Text("cli.panel.title").font(.title2).bold()
            Spacer()
            Button("common.done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(16)
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
