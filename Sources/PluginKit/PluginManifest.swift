import Foundation

/// The manifest every `.pxplugin` package must carry at its root as `manifest.json`.
/// Field contract: docs/plugin-store-phase1.md §4.2; permission semantics:
/// docs/sdk-permission-api.md §4. A manifest declaration is not authorization.
public struct PluginManifest: Codable, Equatable, Sendable {
    public static let currentFormatVersion = 1

    public var formatVersion: Int
    public var id: String
    public var name: String
    public var version: String
    public var description: String
    public var author: String
    public var sdkVersion: String
    public var permissions: [PermissionDeclaration]
    public var entryPoint: String

    public struct PermissionDeclaration: Codable, Equatable, Sendable {
        public var id: String
        public var required: Bool
        public var reason: String

        public init(id: String, required: Bool, reason: String) {
            self.id = id
            self.required = required
            self.reason = reason
        }
    }

    public init(
        formatVersion: Int = PluginManifest.currentFormatVersion,
        id: String,
        name: String,
        version: String,
        description: String,
        author: String,
        sdkVersion: String,
        permissions: [PermissionDeclaration],
        entryPoint: String
    ) {
        self.formatVersion = formatVersion
        self.id = id
        self.name = name
        self.version = version
        self.description = description
        self.author = author
        self.sdkVersion = sdkVersion
        self.permissions = permissions
        self.entryPoint = entryPoint
    }
}

/// Errors raised while validating or installing a `.pxplugin` package. Messages are
/// user-facing: the Plugin Store shows them verbatim when a package is rejected.
public enum PluginPackageError: Error, Equatable, Sendable {
    case invalidArchive(String)
    case invalidManifest(String)
    case unsupportedVersion(Int)
    case resourceLimit(String)
    case collision(String)
}

public extension PluginManifest {
    /// Structural validation that does not depend on installed-plugin state. Whether
    /// every declared permission id is known to the host is checked together with the
    /// package contents, since both are package-level rejections.
    func validated() throws {
        guard formatVersion == Self.currentFormatVersion else {
            throw PluginPackageError.unsupportedVersion(formatVersion)
        }
        try Self.validateIdentifier(id)
        guard !name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginPackageError.invalidManifest("Plugin name must not be blank.")
        }
        guard !author.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw PluginPackageError.invalidManifest("Plugin author must not be blank.")
        }
        guard PluginSemver(parsing: version) != nil else {
            throw PluginPackageError.invalidManifest("Version '\(version)' is not a semantic version.")
        }
        guard PluginSemverRange(parsing: sdkVersion) != nil else {
            throw PluginPackageError.invalidManifest("sdkVersion '\(sdkVersion)' is not a supported semver range.")
        }
        var seen = Set<String>()
        for permission in permissions {
            try Self.validatePermissionID(permission.id)
            guard seen.insert(permission.id).inserted else {
                throw PluginPackageError.invalidManifest("Permission '\(permission.id)' is declared more than once.")
            }
        }
        try Self.validateRelativePath(entryPoint, label: "entryPoint")
        guard entryPoint != "manifest.json", !entryPoint.hasPrefix("\(PluginPackageArchive.resourcesRoot)/") else {
            throw PluginPackageError.invalidManifest("entryPoint must be the plugin executable, not '\(entryPoint)'.")
        }
    }

    /// True when the host SDK version satisfies the manifest's `sdkVersion` range.
    func isCompatibleWithHostSDK() -> Bool {
        (PluginSemverRange(parsing: sdkVersion)?.isSatisfiedByHostSDK()) ?? false
    }

    func declaredPermissionIDs() -> Set<String> {
        Set(permissions.map(\.id))
    }

    /// Reverse-DNS-style plugin identifier, e.g. `com.example.response-mapper`. At
    /// least two dot-separated segments of letters, digits, hyphens, or underscores;
    /// this doubles as the installed-directory name, so `.` and `/` are excluded.
    static func validateIdentifier(_ id: String) throws {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2,
              segments.allSatisfy({
                  !$0.isEmpty
                      && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
              }) else {
            throw PluginPackageError.invalidManifest(
                "Plugin id '\(id)' must be a reverse-DNS identifier such as com.example.response-mapper."
            )
        }
    }

    /// Permission identifiers use dotted lowercase tokens like `local-map.read`.
    static func validatePermissionID(_ id: String) throws {
        let segments = id.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 1,
              segments.allSatisfy({
                  !$0.isEmpty
                      && $0.unicodeScalars.allSatisfy { CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_").contains($0) }
              }) else {
            throw PluginPackageError.invalidManifest("Permission id '\(id)' is not a valid permission identifier.")
        }
    }

    /// Package-relative paths must stay inside the package root.
    static func validateRelativePath(_ path: String, label: String) throws {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else {
            throw PluginPackageError.invalidManifest("\(label) '\(path)' is not a safe package-relative path.")
        }
        let parts = path.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw PluginPackageError.invalidManifest("\(label) '\(path)' is not a safe package-relative path.")
        }
    }
}
