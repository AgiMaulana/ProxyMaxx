import SwiftUI
import FlowKit
import ClientKit

struct ClientAppLabel: View {
    let app: ClientApp
    var showsIdentity = false

    var body: some View {
        HStack(spacing: 6) {
            Group {
                if let icon = ClientIconCache.shared.icon(for: app) {
                    Image(nsImage: icon)
                        .resizable()
                        .scaledToFit()
                } else {
                    Image(systemName: "app")
                        .resizable()
                        .scaledToFit()
                        .foregroundStyle(.secondary)
                }
            }
            .frame(width: 16, height: 16)
            .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(app.name)
                    .lineLimit(1)
                if showsIdentity, let identity = app.bundleIdentifier ?? app.path {
                    Text(identity)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .help(tooltip)
        .accessibilityElement(children: .combine)
    }

    private var tooltip: String {
        var text = app.name
        if let bundleIdentifier = app.bundleIdentifier { text += "\n\(bundleIdentifier)" }
        if let path = app.path { text += "\n\(path)" }
        return text
    }
}
