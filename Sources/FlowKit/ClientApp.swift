import Foundation

/// Local process attribution retained in captured sessions.
public struct ClientApp: Codable, Hashable, Sendable {
    /// App display name, or executable name for an unbundled process.
    public let name: String
    /// `CFBundleIdentifier` of the owning app bundle, when there is one.
    public let bundleIdentifier: String?
    /// App bundle or executable path used for icon lookup.
    public let path: String?
    public let pid: Int32?

    public init(name: String, bundleIdentifier: String? = nil, path: String? = nil, pid: Int32? = nil) {
        self.name = name
        self.bundleIdentifier = bundleIdentifier
        self.path = path
        self.pid = pid
        if let bundleIdentifier {
            self.id = "bundle:" + bundleIdentifier
        } else if let path {
            self.id = "path:" + path
        } else {
            self.id = "name:" + name
        }
    }

    /// Group across process restarts without merging unrelated apps with the same name.
    public let id: String

    private enum CodingKeys: String, CodingKey {
        case name, bundleIdentifier, path, pid
    }

    /// Older sessions stored only the display name.
    public init(from decoder: Decoder) throws {
        if let single = try? decoder.singleValueContainer(), let name = try? single.decode(String.self) {
            self.init(name: name)
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            name: try container.decode(String.self, forKey: .name),
            bundleIdentifier: try container.decodeIfPresent(String.self, forKey: .bundleIdentifier),
            path: try container.decodeIfPresent(String.self, forKey: .path),
            pid: try container.decodeIfPresent(Int32.self, forKey: .pid)
        )
    }
}

/// Resolve once per accepted connection, off the caller's event loop.
public protocol ClientAppResolving: Sendable {
    /// Addresses are numeric IPs; the tuple is oriented from client to proxy.
    func resolveClientApp(
        clientAddress: String,
        clientPort: Int,
        proxyAddress: String,
        proxyPort: Int,
        completion: @escaping @Sendable (ClientApp?) -> Void
    )
}
