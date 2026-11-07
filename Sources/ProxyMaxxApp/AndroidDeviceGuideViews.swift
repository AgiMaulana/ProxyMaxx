import SwiftUI
import AppKit
import SystemKit

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
                            Text("android.device.step1Hint").font(.callout)
                            proxyStep
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

    private var proxyStep: some View {
        let host = AndroidToolchain.lanIPv4Address() ?? L10n.string("android.device.lanPlaceholder")
        return Text("\(host):\(model.port)")
            .font(.system(.callout, design: .monospaced))
            .textSelection(.enabled)
            .padding(8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(nsColor: .textBackgroundColor))
            .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    private func exportCA() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "proxymaxx-ca.crt"
        panel.allowedContentTypes = []
        if panel.runModal() == .OK, let url = panel.url {
            model.exportCertificate(to: url)
        }
    }
}
