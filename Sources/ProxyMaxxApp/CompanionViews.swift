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
    @State private var copiedCommand: String?

    private var toolURL: URL { model.commandLineToolURL }
    private var isInstalled: Bool {
        FileManager.default.isExecutableFile(atPath: toolURL.path)
    }
    private var exportCommand: String {
        "\(quoted(toolURL.path)) export"
    }
    /// The same change, applied to the terminal the user is sitting in. A new terminal
    /// would read the profile block; this one has to be told now. Only zsh users get a
    /// one-liner here, because the CLI already names the right file for the others.
    private var applyCommand: String? {
        ShellPathExport.detectShell() == .zsh ? "source ~/.zshrc" : nil
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

    /// The `export` half of the panel: what the command does, and how to apply it to the
    /// terminal already open. The CLI cannot edit its parent shell's environment, so the
    /// profile block is what makes the change last and `source`/`eval` is what makes it
    /// immediate.
    private var pathExportSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("cli.panel.export.title").font(.headline)
            Text("cli.panel.export.intro")
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)

            commandRow(exportCommand)

            if let applyCommand {
                Text("cli.panel.export.applyTitle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                commandRow(applyCommand)
            }
        }
    }

    private func commandRow(_ command: String) -> some View {
        HStack(spacing: 8) {
            Text(command)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color(nsColor: .textBackgroundColor))
                .clipShape(RoundedRectangle(cornerRadius: 5))
            Button(copiedCommand == command ? L10n.string("common.copied") : L10n.string("companion.copyCommand")) {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(command, forType: .string)
                copiedCommand = command
            }
        }
    }

    private func quoted(_ path: String) -> String {
        guard path.contains(" ") else { return path }
        return "'" + path.replacingOccurrences(of: "'", with: "'\\''") + "'"
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
