import SwiftUI
import RuleKit

struct MapLocalImportPreview: Identifiable, Sendable {
    let id = UUID()
    let archiveURL: URL
    let manifest: MapLocalBundleManifest
}

/// A parsed HAR document held between "Import HAR…" and the commit step.
struct HARImportPreview: Identifiable, Sendable {
    let id = UUID()
    let entries: [HAREntry]
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

/// Preview sheet for a HAR import: the entries that would become local overrides,
/// with an option to keep only successful responses.
struct HARImportPreviewView: View {
    let preview: HARImportPreview
    let onImport: (_ skipNonSuccess: Bool) throws -> Void

    @Environment(\.dismiss) private var dismiss
    @State private var skipNonSuccess = true
    @State private var errorMessage: String?

    private struct EntryRow: Identifiable {
        let entry: HAREntry
        var id: String { "\(entry.request?.url ?? "")-\(entry.response?.status ?? 0)" }

        var method: String { entry.request?.method ?? "" }
        var url: String { entry.request?.url ?? "" }
        var status: Int { entry.response?.status ?? 0 }
        var sizeText: String {
            guard let size = entry.response?.content?.size, size >= 0 else { return "—" }
            return ByteCountFormatter.string(fromByteCount: Int64(size), countStyle: .file)
        }
    }

    /// Entries a rule can actually be built from: a URL and a response body.
    private var importableRows: [EntryRow] {
        preview.entries.filter { HARImporter.hasBody($0) }.map(EntryRow.init(entry:))
    }

    private var shownRows: [EntryRow] {
        skipNonSuccess ? importableRows.filter { (200..<300).contains($0.status) } : importableRows
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("mapLocal.har.previewTitle").font(.title3).bold()
                Text(L10n.format("mapLocal.har.previewCount", shownRows.count, importableRows.count))
                    .font(.caption)
                Text("mapLocal.har.previewHelp")
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(16)

            Divider()
            Table(shownRows) {
                TableColumn("common.method") { row in
                    Text(row.method).font(.system(.caption, design: .monospaced))
                }
                .width(65)
                TableColumn("mapLocal.matchingURLs") { row in
                    Text(row.url)
                        .font(.system(.caption, design: .monospaced))
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help(row.url)
                }
                TableColumn("common.status") { row in
                    Text("\(row.status)").monospacedDigit()
                }
                .width(60)
                TableColumn("mapLocal.har.sizeColumn") { row in
                    Text(row.sizeText).monospacedDigit()
                }
                .width(80)
            }
            .overlay {
                if shownRows.isEmpty {
                    Text("mapLocal.har.noEntries").padding(24)
                }
            }

            Divider()
            VStack(alignment: .leading, spacing: 8) {
                Toggle("mapLocal.har.skipNonSuccess", isOn: $skipNonSuccess)
                    .toggleStyle(.checkbox)
                HStack {
                    Spacer()
                    Button("common.cancel") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                    Button("mapLocal.bundle.import") {
                        do {
                            try onImport(skipNonSuccess)
                            dismiss()
                        } catch {
                            errorMessage = error.localizedDescription
                        }
                    }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
                    .disabled(shownRows.isEmpty)
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
