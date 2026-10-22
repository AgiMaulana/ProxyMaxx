import Foundation

/// Locates the `proxymaxx-cli` that ships inside the app bundle.
///
/// The CLI is an app artifact, not a separate download, so the path the window shows has to
/// agree with the one `Scripts/bundle-app.sh` writes. During `swift run` there is no app
/// bundle, so fall back to the checkout's staged copy and let the caller name a missing
/// build instead of hiding it.
public enum CLICompanion {
    public static let binaryName = "proxymaxx-cli"

    /// The executable to run: the bundled copy, the checkout's build artifact, or the path
    /// the bundle would use when neither exists.
    public static func binaryURL(bundle: Bundle = .main) -> URL {
        let resources = bundle.resourceURL ?? bundle.bundleURL
        let bundled = resources.appendingPathComponent(binaryName)
        if FileManager.default.isExecutableFile(atPath: bundled.path) {
            return bundled
        }

        let checkout = packageRoot.appendingPathComponent("Resources/\(binaryName)")
        if FileManager.default.isExecutableFile(atPath: checkout.path) {
            return checkout
        }

        return bundled
    }

    private static var packageRoot: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }
}
