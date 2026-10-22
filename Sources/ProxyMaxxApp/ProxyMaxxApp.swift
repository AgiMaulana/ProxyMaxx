import SwiftUI
import AppKit

/// Copy shared by the Settings pane and the standard About panel, so the two cannot drift.
enum ProxyMaxxAbout {
    static let summary = L10n.string("settings.aboutText")

    static func showPanel() {
        let paragraph = NSMutableParagraphStyle()
        paragraph.alignment = .center
        paragraph.lineSpacing = 4
        let credits = NSAttributedString(
            string: summary,
            attributes: [
                .font: NSFont.systemFont(ofSize: NSFont.smallSystemFontSize),
                .foregroundColor: NSColor.secondaryLabelColor,
                .paragraphStyle: paragraph,
            ]
        )
        NSApplication.shared.orderFrontStandardAboutPanel(options: [
            .applicationName: "ProxyMaxx",
            .credits: credits,
        ])
    }
}

@main
struct ProxyMaxxApp: App {
    @StateObject private var model = AppModel()
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    init() {
        // `swift run` launches an unbundled binary; make sure it behaves like a real app.
        if Bundle.main.bundleIdentifier == nil {
            NSApplication.shared.setActivationPolicy(.regular)
        }
    }

    var body: some Scene {
        WindowGroup("ProxyMaxx") {
            MainView(flowStore: model.flowStore)
                .environmentObject(model)
                .frame(minWidth: 1040, minHeight: 640)
                .onAppear { appDelegate.model = model }
        }
        .commands {
            CommandGroup(replacing: .newItem) {}
            CommandGroup(replacing: .appInfo) {
                Button("menu.about") { ProxyMaxxAbout.showPanel() }
            }
            CommandGroup(after: .appInfo) {
                Button("menu.clearSession") { model.clearSession() }
                    .keyboardShortcut("k", modifiers: [.command, .shift])

                Divider()

                Button("menu.mapLocal") { model.showMapLocalWindow = true }
                    .keyboardShortcut("l", modifiers: .command)

                Divider()

                Button("cert.installAndroid") {
                    model.refreshAndroidDevices()
                    model.showAndroidEmulatorGuide = true
                }
                Button("menu.androidEmulator") {
                    model.refreshAndroidDevices()
                    model.showAndroidEmulatorGuide = true
                }
                Button("menu.androidDevice") {
                    model.showAndroidDeviceGuide = true
                }

                Divider()

                Button("menu.installBrowserExtension") {
                    model.installBrowserExtension()
                }
                Button("menu.commandLineTool") {
                    model.showCommandLinePanel = true
                }
            }
        }

        Settings {
            SettingsView()
                .environmentObject(model)
        }
    }
}
