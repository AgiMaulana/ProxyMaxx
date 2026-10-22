import Foundation

/// The on-disk shape of the rule file, shared by the app and the CLI.
///
/// Both write the same JSON, so `proxymaxx-cli rule add` and the app agree on every byte of
/// `Application Support/ProxyMaxx/rules.json`. Field names must not change without a
/// migration: an older build reading a newer file loses everything it cannot decode.
public struct RuleFile: Codable, Equatable, Sendable {
    public var isSSLProxyingEnabled: Bool
    public var sslProxyingPolicy: SSLProxyingPolicy
    public var isMapLocalEnabled: Bool
    public var mapLocalRules: [MapLocalRule]

    public init(
        isSSLProxyingEnabled: Bool = true,
        sslProxyingPolicy: SSLProxyingPolicy = .decryptAll,
        isMapLocalEnabled: Bool = true,
        mapLocalRules: [MapLocalRule] = []
    ) {
        self.isSSLProxyingEnabled = isSSLProxyingEnabled
        self.sslProxyingPolicy = sslProxyingPolicy
        self.isMapLocalEnabled = isMapLocalEnabled
        self.mapLocalRules = mapLocalRules
    }

    /// Read a rule file, falling back to defaults when it is missing or corrupt.
    public static func load(from url: URL) -> RuleFile {
        guard let data = try? Data(contentsOf: url),
              let file = try? JSONDecoder().decode(RuleFile.self, from: data)
        else { return RuleFile() }
        return file
    }

    /// Write the rule file atomically, creating its parent directory as needed.
    public func write(to url: URL) throws {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(self)
        try FileManager.default.createDirectory(
            at: url.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try data.write(to: url, options: .atomic)
    }
}
