import Foundation
import Darwin
import ZIPFoundation

/// Reads and installs `.pxplugin` packages (format 1 ZIP, docs/plugin-store-phase1.md
/// §4–§5). Layout: `manifest.json` at the root, the plugin executable named by the
/// manifest's `entryPoint`, and optional resources under `resources/`.
///
/// The validation walk mirrors RuleKit's `MapLocalBundleArchive`: snapshot copy, a
/// header-verified ZIP, allowlisted paths, streamed extraction with checksum and size
/// verification, and a staging directory moved into place only after everything
/// succeeded. The entry point is never executed here — PluginRunner does that, and
/// only after the user has confirmed an install.
public enum PluginPackageArchive {
    static let manifestEntry = "manifest.json"
    static let resourcesRoot = "resources"

    /// Validate-only read for the installation preview (docs §5.3).
    public static func inspect(_ packageURL: URL) throws -> PluginManifest {
        try withSnapshot(of: packageURL) { snapshot in
            try validatedPackage(at: snapshot).manifest
        }
    }

    /// Validate and extract a package into `installationRoot` (…/plugins/installed).
    /// Returns the manifest and the managed directory that now holds the contents.
    /// Duplicate plugin ids are rejected (docs §5.2).
    public static func install(
        from packageURL: URL,
        installationRoot: URL,
        existingPluginIDs: Set<String>
    ) throws -> (manifest: PluginManifest, directory: URL) {
        try withSnapshot(of: packageURL) { snapshot in
            let validated = try validatedPackage(at: snapshot)
            let manifest = validated.manifest
            guard !existingPluginIDs.contains(manifest.id) else {
                throw PluginPackageError.collision("Plugin '\(manifest.id)' is already installed.")
            }
            let manager = FileManager.default
            let managed = installationRoot.appendingPathComponent(manifest.id, isDirectory: true)
            guard (try? manager.attributesOfItem(atPath: managed.path)) == nil else {
                throw PluginPackageError.collision("Installed directory already exists: \(managed.path)")
            }
            try manager.createDirectory(at: installationRoot, withIntermediateDirectories: true)
            let stage = installationRoot.appendingPathComponent(".install-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false)
            var extracted = false
            var committed = false
            defer {
                try? manager.removeItem(at: stage)
                if extracted && !committed { try? manager.removeItem(at: managed) }
            }
            for item in validated.items where item.path != manifestEntry {
                let destination = stage.appendingPathComponent(item.path, isDirectory: item.entry.type == .directory)
                if item.entry.type == .directory {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard manager.createFile(atPath: destination.path, contents: nil) else {
                        throw PluginPackageError.invalidArchive("Cannot extract '\(item.path)'.")
                    }
                    let handle = try FileHandle(forWritingTo: destination)
                    defer { try? handle.close() }
                    try read(item, from: validated.archive) { try handle.write(contentsOf: $0) }
                }
            }
            // The runner spawns the entry point directly, so it needs the exec bit —
            // ZIP extraction does not preserve Unix modes on all writers.
            let entryPoint = stage.appendingPathComponent(manifest.entryPoint)
            try manager.setAttributes([.posixPermissions: 0o755], ofItemAtPath: entryPoint.path)
            try manager.moveItem(at: stage, to: managed)
            extracted = true
            committed = true
            return (manifest, managed)
        }
    }

    private struct Item {
        let entry: Entry
        let path: String
        let record: PluginPackageZIPStructure.Record
    }

    private struct Validated {
        let archive: Archive
        let items: [Item]
        let manifest: PluginManifest
    }

    private static func validatedPackage(at url: URL) throws -> Validated {
        let structure = try PluginPackageZIPStructure(url: url)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        guard entries.count == structure.records.count else {
            throw PluginPackageError.invalidArchive("One or more ZIP entries are unreadable.")
        }
        var items: [Item] = []
        var paths: [String: Bool] = [:]
        for (entry, record) in zip(entries, structure.records) {
            let isDirectory = entry.type == .directory
            guard entry.type != .symlink, isDirectory == record.directory,
                  entry.checksum == record.checksum,
                  entry.compressedSize == record.compressedSize,
                  entry.uncompressedSize == record.uncompressedSize else {
                throw PluginPackageError.invalidArchive("Entry metadata is inconsistent for '\(entry.path)'.")
            }
            let path = isDirectory ? String(entry.path.dropLast()) : entry.path
            try validateArchivePath(path, directory: isDirectory)
            guard path != manifestEntry || !isDirectory, path != resourcesRoot || isDirectory else {
                throw PluginPackageError.invalidArchive("Invalid manifest or resource root type.")
            }
            guard paths.updateValue(isDirectory, forKey: pathKey(path)) == nil else {
                throw PluginPackageError.invalidArchive("Duplicate or filesystem-equivalent path '\(path)'.")
            }
            items.append(Item(entry: entry, path: path, record: record))
        }
        guard let manifestItem = items.first(where: { $0.path == manifestEntry }) else {
            throw PluginPackageError.invalidArchive("Missing \(manifestEntry).")
        }
        guard manifestItem.record.uncompressedSize <= PluginPackageZIPStructure.maximumManifestBytes else {
            throw PluginPackageError.resourceLimit("\(manifestEntry) exceeds 1 MiB.")
        }
        var manifestData = Data()
        try read(manifestItem, from: archive) { manifestData.append($0) }
        let manifest: PluginManifest
        do { manifest = try JSONDecoder().decode(PluginManifest.self, from: manifestData) }
        catch { throw PluginPackageError.invalidManifest("manifest.json is not a valid plugin manifest: \(error.localizedDescription)") }
        try manifest.validated()

        // Permission identifiers are checked against the host registry here: a package
        // naming an unknown permission is rejected outright (docs §5.2, §6).
        for permission in manifest.permissions {
            guard PluginPermissionRegistry.isSupported(permission.id) else {
                throw PluginPackageError.invalidManifest("Unknown permission '\(permission.id)'; plugins cannot declare permissions the host does not support.")
            }
        }

        // SDK compatibility is a package-level rejection, independent of permissions.
        guard manifest.isCompatibleWithHostSDK() else {
            throw PluginPackageError.invalidManifest(
                "Plugin requires SDK \(manifest.sdkVersion) but ProxyMaxx provides \(PluginSDK.version)."
            )
        }

        // Now that the manifest names the entry point, the allowlist is checkable:
        // everything except manifest.json, the entry point (and its parent
        // directories), and resources/ is rejected.
        for item in items {
            let isEntryPointAncestor = item.record.directory && manifest.entryPoint.hasPrefix("\(item.path)/")
            guard item.path == manifestEntry
                    || item.path == resourcesRoot || item.path.hasPrefix("\(resourcesRoot)/")
                    || item.path == manifest.entryPoint || isEntryPointAncestor else {
                throw PluginPackageError.invalidArchive("Unexpected entry '\(item.path)'; resources belong under \(resourcesRoot)/.")
            }
        }

        // The entry point must be an exact file entry in the package.
        guard let entryPointItem = items.first(where: { $0.path == manifest.entryPoint }) else {
            throw PluginPackageError.invalidManifest("Entry point '\(manifest.entryPoint)' is missing from the package.")
        }
        guard !entryPointItem.record.directory else {
            throw PluginPackageError.invalidManifest("Entry point '\(manifest.entryPoint)' is not a file.")
        }
        return Validated(archive: archive, items: items, manifest: manifest)
    }

    private static func read(_ item: Item, from archive: Archive, consumer: (Data) throws -> Void) throws {
        var count: UInt64 = 0
        let checksum: UInt32
        do {
            checksum = try archive.extract(item.entry) { data in
                count += UInt64(data.count)
                guard count <= item.record.uncompressedSize else {
                    throw PluginPackageError.invalidArchive("Expanded data exceeds the declared size for '\(item.path)'.")
                }
                try consumer(data)
            }
        } catch let error as PluginPackageError { throw error }
        catch { throw PluginPackageError.invalidArchive("Cannot read '\(item.path)': \(error.localizedDescription)") }
        guard count == item.record.uncompressedSize, checksum == item.record.checksum else {
            throw PluginPackageError.invalidArchive("Size or CRC checksum mismatch for '\(item.path)'.")
        }
    }

    private static func validateArchivePath(_ path: String, directory: Bool) throws {
        try PluginManifest.validateRelativePath(path, label: "Archive path")
        guard !path.hasSuffix("/") || directory else {
            throw PluginPackageError.invalidArchive("Unsafe archive path '\(path)'.")
        }
    }

    private static func pathKey(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    /// Copy to a private snapshot first, so a package that changes (or is replaced by a
    /// symlink) mid-read cannot turn validation into a race.
    private static func withSnapshot<T>(of url: URL, body: (URL) throws -> T) throws -> T {
        guard url.isFileURL else {
            throw PluginPackageError.invalidArchive("Package input must be a local ZIP file.")
        }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw PluginPackageError.invalidArchive("Package input is not a regular ZIP file.")
        }
        guard ((attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= PluginPackageZIPStructure.maximumArchiveBytes else {
            throw PluginPackageError.resourceLimit("Package exceeds 256 MiB plus metadata.")
        }
        let temporary = manager.temporaryDirectory.appendingPathComponent("pxplugin-read-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("package.pxplugin")
        try manager.copyItem(at: url, to: snapshot)
        let snapshotAttributes = try manager.attributesOfItem(atPath: snapshot.path)
        guard snapshotAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw PluginPackageError.invalidArchive("Package input changed to a non-regular file while being copied.")
        }
        return try body(snapshot)
    }
}
