import AppKit
import FlowKit

/// Main-actor cache shared by the sidebar, traffic table, and inspector.
@MainActor
public final class ClientIconCache {
    public static let shared = ClientIconCache()

    private final class CachedIcon {
        let image: NSImage?

        init(_ image: NSImage?) {
            self.image = image
        }
    }

    private let images = NSCache<NSString, CachedIcon>()

    private init() {
        images.countLimit = 256
    }

    public func icon(for app: ClientApp) -> NSImage? {
        guard let path = app.path, !path.isEmpty else { return nil }
        let key = path as NSString
        if let cached = images.object(forKey: key) { return cached.image }
        let image = FileManager.default.fileExists(atPath: path)
            ? NSWorkspace.shared.icon(forFile: path)
            : nil
        images.setObject(CachedIcon(image), forKey: key)
        return image
    }
}
