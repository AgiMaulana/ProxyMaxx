import SwiftUI
import AppKit
import SystemKit

/// The result of installing the browser companion: the folder the browser loads, and the
/// host manifests written for it.
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
                Text("browser.panel.steps")
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

    private var toolURL: URL { model.commandLineToolURL }

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
                if !FileManager.default.isExecutableFile(atPath: toolURL.path) {
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
