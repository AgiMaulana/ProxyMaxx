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
    /// Named sets of Map Local rules. Absent from files written before scenarios existed,
    /// which decode as an empty list thanks to `init(from:)` below.
    public var mapLocalScenarios: [MapLocalScenario]

    public init(
        isSSLProxyingEnabled: Bool = true,
        sslProxyingPolicy: SSLProxyingPolicy = .decryptAll,
        isMapLocalEnabled: Bool = true,
        mapLocalRules: [MapLocalRule] = [],
        mapLocalScenarios: [MapLocalScenario] = []
    ) {
        self.isSSLProxyingEnabled = isSSLProxyingEnabled
        self.sslProxyingPolicy = sslProxyingPolicy
        self.isMapLocalEnabled = isMapLocalEnabled
        self.mapLocalRules = mapLocalRules
        self.mapLocalScenarios = mapLocalScenarios
    }

    private enum CodingKeys: String, CodingKey {
        case isSSLProxyingEnabled
        case sslProxyingPolicy
        case isMapLocalEnabled
        case mapLocalRules
        case mapLocalScenarios
    }

    /// Synthesised decoding would reject a file without `mapLocalScenarios`, which every
    /// build before this one wrote. Decode it as empty so upgrading never loses rules.
    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        isSSLProxyingEnabled = try container.decode(Bool.self, forKey: .isSSLProxyingEnabled)
        sslProxyingPolicy = try container.decode(SSLProxyingPolicy.self, forKey: .sslProxyingPolicy)
        isMapLocalEnabled = try container.decode(Bool.self, forKey: .isMapLocalEnabled)
        mapLocalRules = try container.decode([MapLocalRule].self, forKey: .mapLocalRules)
        mapLocalScenarios = try container.decodeIfPresent([MapLocalScenario].self, forKey: .mapLocalScenarios) ?? []
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
