import Foundation

/// Product identity that more than one module has to agree on.
public enum Brand {
    public static let displayName = "ProxyMaxx"
    public static let bundleIdentifier = "com.proxymaxx.app"
    public static let supportDirectoryName = "ProxyMaxx"

    /// `~/Library/Application Support/ProxyMaxx`.
    public static var supportDirectory: URL {
        let base = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)
            .first ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent(supportDirectoryName, isDirectory: true)
    }
}
