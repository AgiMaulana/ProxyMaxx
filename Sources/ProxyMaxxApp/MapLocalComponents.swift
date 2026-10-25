import SwiftUI
import RuleKit

struct MapLocalImportPreview: Identifiable, Sendable {
    let id = UUID()
    let archiveURL: URL
    let manifest: MapLocalBundleManifest
}

struct MapLocalBundleImportView: View {
    let preview: MapLocalImportPreview
    let onImport: (Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var activate = false
    @State private var errorMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("mapLocal.bundle.previewTitle").font(.title3).bold()
                Text(preview.manifest.name).font(.headline).textSelection(.enabled)
                Text(L10n.format("mapLocal.bundle.previewCount", preview.manifest.overrides.count))
                    .font(.caption)
                Text("mapLocal.bundle.previewHelp")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()
            Table(preview.manifest.overrides) {
                TableColumn("common.name") { rule in
                    Text(rule.displayName).lineLimit(1).help(rule.displayName)
                }
                .width(min: 100, ideal: 130, max: 150)
                TableColumn("common.method") { rule in
                    Text(rule.method.displayName).font(.system(.caption, design: .monospaced))
                }
                .width(65)
                TableColumn("mapLocal.matchStyleColumn") { rule in
                    Text(rule.matchStyle.displayName).lineLimit(1)
                }
                .width(110)
                TableColumn("mapLocal.matchingURLs") { rule in
                    Text(rule.url)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.url)
                }
                .width(min: 150, ideal: 180, max: 210)
                TableColumn("mapLocal.bundle.responseReference") { rule in
                    Label(rule.destination.path, systemImage: rule.destination.symbolName)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(rule.destination.path)
                }
                .width(min: 160, ideal: 200, max: 240)
            }
            .overlay {
                if preview.manifest.overrides.isEmpty {
                    Text("mapLocal.bundle.noRules").padding(24)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("mapLocal.bundle.activateOnImport", isOn: $activate)
                    .toggleStyle(.checkbox)
                    .disabled(preview.manifest.overrides.isEmpty)
                Text("mapLocal.bundle.activateHelp")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Spacer()
                    Button("common.cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("mapLocal.bundle.import") {
                        do {
                            try onImport(activate)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(16)
        }
        .frame(width: 880, height: 580)
        .alert("mapLocal.bundle.errorTitle", isPresented: Binding(
            get: { errorMessage != nil },
            set: { if !$0 { errorMessage = nil } }
        )) {
            Button("common.ok", role: .cancel) { errorMessage = nil }
        } message: {
            Text(errorMessage ?? "")
        }
    }
}
