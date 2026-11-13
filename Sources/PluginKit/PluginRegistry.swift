import Foundation
import Branding

/// A plugin registered by the Plugin Store: its validated manifest plus when it was
/// installed. Identity is the manifest id, which permission decisions key off.
public struct InstalledPlugin: Codable, Equatable, Identifiable, Sendable {
    public var manifest: PluginManifest
    public var installedAt: Date

    public init(manifest: PluginManifest, installedAt: Date = Date()) {
        self.manifest = manifest
        self.installedAt = installedAt
    }

    public var id: String { manifest.id }
    public var name: String { manifest.name }
    public var version: String { manifest.version }
}

public enum PluginRegistryError: Error, Equatable {
    case unknownPlugin(String)
}

/// Tracks installed plugins on disk (docs/plugin-store-phase1.md §5, §11). Layout
/// under the plugin directory:
///
///   registry.json            installed plugin metadata
///   installed/<plugin-id>/   extracted package contents
///
/// Uninstallation removes the registration and the package files; permission
/// decisions belong to PermissionStore and are removed by its caller.
@MainActor
public final class PluginRegistry: ObservableObject {
    static let registryEntry = "registry.json"

    @Published public private(set) var installedPlugins: [InstalledPlugin] = []

    /// The Plugin Store root, `…/Application Support/ProxyMaxx/plugins` by default.
    /// Injectable so tests work inside their own temporary directory.
    public let directory: URL

    private let encoder: JSONEncoder
    private let decoder: JSONDecoder

    public nonisolated static var defaultDirectory: URL {
        Brand.supportDirectory.appendingPathComponent("plugins", isDirectory: true)
    }

    var installationRoot: URL {
        directory.appendingPathComponent("installed", isDirectory: true)
    }

    var registryURL: URL {
        directory.appendingPathComponent(Self.registryEntry)
    }

    public init(directory: URL = PluginRegistry.defaultDirectory) {
        self.directory = directory
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .prettyPrinted]
        encoder.dateEncodingStrategy = .secondsSince1970
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        self.encoder = encoder
        self.decoder = decoder
        if let data = try? Data(contentsOf: registryURL),
           let plugins = try? decoder.decode([InstalledPlugin].self, from: data) {
            installedPlugins = plugins
        }
    }

    public func plugin(id: String) -> InstalledPlugin? {
        installedPlugins.first { $0.id == id }
    }

    /// Where an installed plugin's package contents live.
    public func installationDirectory(for id: String) -> URL {
        installationRoot.appendingPathComponent(id, isDirectory: true)
    }

    /// The executable the runner would spawn for a plugin.
    public func entryPointURL(for plugin: InstalledPlugin) -> URL {
        installationDirectory(for: plugin.id).appendingPathComponent(plugin.manifest.entryPoint)
    }

    /// Install a local `.pxplugin` package: validate, extract, register. Nothing here
    /// grants permissions — installation and authorization are independent (docs §5.1).
    @discardableResult
    public func install(from packageURL: URL) throws -> InstalledPlugin {
        let existingIDs = Set(installedPlugins.map(\.id))
        let (manifest, installedDirectory) = try PluginPackageArchive.install(
            from: packageURL,
            installationRoot: installationRoot,
            existingPluginIDs: existingIDs
        )
        let plugin = InstalledPlugin(manifest: manifest)
        var candidate = installedPlugins
        candidate.append(plugin)
        do {
            try persist(candidate)
        } catch {
            try? FileManager.default.removeItem(at: installedDirectory)
            throw error
        }
        installedPlugins = candidate
        return plugin
    }

    /// Remove the registration and the installed package files. Throws when the
    /// plugin is unknown or the package files cannot be removed — in that case the
    /// registration stays so the Plugin Store never shows a ghost plugin.
    public func uninstall(id: String) throws {
        guard let index = installedPlugins.firstIndex(where: { $0.id == id }) else {
            throw PluginRegistryError.unknownPlugin(id)
        }
        try FileManager.default.removeItem(at: installationDirectory(for: id))
        var candidate = installedPlugins
        candidate.remove(at: index)
        try persist(candidate)
        installedPlugins = candidate
    }

    private func persist(_ plugins: [InstalledPlugin]) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let data = try encoder.encode(plugins)
        try data.write(to: registryURL, options: .atomic)
    }
}
