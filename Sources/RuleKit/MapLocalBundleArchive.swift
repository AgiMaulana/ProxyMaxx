import Foundation
import Darwin
import ZIPFoundation
import FlowKit

public enum MapLocalBundleArchive {
    public static func inspect(_ archiveURL: URL) throws -> MapLocalBundleManifest {
        try withSnapshot(of: archiveURL) { snapshot in
            try validatedArchive(at: snapshot).manifest
        }
    }

    @discardableResult
    public static func importBundle(
        from archiveURL: URL,
        into file: inout RuleFile,
        storageDirectory: URL,
        activate: Bool = false,
        persistTo: URL? = nil
    ) throws -> MapLocalBundle {
        try withSnapshot(of: archiveURL) { snapshot in
            let validated = try validatedArchive(at: snapshot)
            let manifest = validated.manifest
            guard !file.mapLocalBundles.contains(where: { $0.id == manifest.id }) else {
                throw MapLocalBundleError.collision("Bundle UUID \(manifest.id) already exists.")
            }
            guard !file.mapLocalBundles.contains(where: {
                MapLocalBundleState.normalizedName($0.name) == MapLocalBundleState.normalizedName(manifest.name)
            }) else { throw MapLocalBundleError.collision("Bundle name '\(manifest.name)' already exists.") }
            let existingIDs = Set(file.mapLocalRules.map(\.id))
            let ownedIDs = Set(file.mapLocalBundles.flatMap(\.ruleIDs))
            for rule in manifest.overrides where existingIDs.contains(rule.id) || ownedIDs.contains(rule.id) {
                throw MapLocalBundleError.collision("Rule UUID \(rule.id) already exists.")
            }
            let manager = FileManager.default
            let root = try MapLocalBundleStorage.root(storageDirectory, create: true)
            let managed = root.appendingPathComponent(manifest.id.uuidString, isDirectory: true)
            guard (try? manager.attributesOfItem(atPath: managed.path)) == nil else {
                throw MapLocalBundleError.collision("Managed directory already exists: \(managed.path)")
            }
            let stage = root.appendingPathComponent(".import-\(UUID().uuidString)", isDirectory: true)
            try manager.createDirectory(at: stage, withIntermediateDirectories: false)
            var installed = false
            var committed = false
            defer {
                try? manager.removeItem(at: stage)
                if installed && !committed { try? manager.removeItem(at: managed) }
            }
            for item in validated.items where item.path != "manifest.json" {
                let destination = stage.appendingPathComponent(item.path, isDirectory: item.entry.type == .directory)
                if item.entry.type == .directory {
                    try manager.createDirectory(at: destination, withIntermediateDirectories: true)
                } else {
                    try manager.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
                    guard manager.createFile(atPath: destination.path, contents: nil) else {
                        throw CocoaError(.fileWriteUnknown, userInfo: [NSFilePathErrorKey: destination.path])
                    }
                    let handle = try FileHandle(forWritingTo: destination)
                    defer { try? handle.close() }
                    try read(item, from: validated.archive) { try handle.write(contentsOf: $0) }
                }
            }
            let bundle = MapLocalBundle(id: manifest.id, name: manifest.name, ruleIDs: manifest.overrides.map(\.id))
            var candidate = file
            candidate.mapLocalRules += manifest.overrides.map { rule in
                var imported = rule
                let absolute = managed.appendingPathComponent(rule.destination.path).path
                imported.destination = rule.destination.isFile ? .file(absolute) : .directory(absolute)
                imported.isEnabled = false
                return imported
            }
            candidate.mapLocalBundles.append(bundle)
            if activate { try MapLocalBundleState.activate(id: bundle.id, in: &candidate) }
            try manager.moveItem(at: stage, to: managed)
            installed = true
            if let persistTo { try candidate.write(to: persistTo) }
            file = candidate
            committed = true
            return bundle
        }
    }

    public static func exportBundle(
        rules: [MapLocalRule], name: String, id: UUID = UUID(), to archiveURL: URL
    ) throws {
        guard archiveURL.isFileURL else { throw MapLocalBundleError.invalidArchive("Export destination must be a local ZIP path.") }
        var manifest = MapLocalBundleManifest(id: id, name: name, overrides: rules)
        try validateRules(manifest)
        let manager = FileManager.default
        let parent = archiveURL.deletingLastPathComponent()
        try manager.createDirectory(at: parent, withIntermediateDirectories: true)
        if let attributes = try? manager.attributesOfItem(atPath: archiveURL.path),
           attributes[.type] as? FileAttributeType != .typeRegular {
            throw MapLocalBundleError.invalidArchive("Export destination is not a regular file: \(archiveURL.path)")
        }
        let temporary = parent.appendingPathComponent(".bundle-export-\(UUID().uuidString).zip")
        defer { try? manager.removeItem(at: temporary) }
        let archive = try Archive(url: temporary, accessMode: .create)
        var budget = ExportBudget()
        try addDirectory("map-local", to: archive, budget: &budget)
        for index in rules.indices {
            let rule = rules[index]
            let source = MapLocalResponder.expand(rule.destination.path).standardizedFileURL
            let basename = source.lastPathComponent
            try validatePath("map-local/\(rule.id.uuidString)/\(basename)", directory: false)
            let container = "map-local/\(rule.id.uuidString)"
            let destination = container + "/" + basename
            try addDirectory(container, to: archive, budget: &budget)
            let type = try sourceType(source)
            guard type == (rule.destination.isFile ? .typeRegular : .typeDirectory) else {
                throw MapLocalBundleError.invalidRule("'\(rule.displayName)' destination type does not match \(source.path).")
            }
            if rule.destination.isFile {
                try addFile(source, path: destination, resolvePointers: true, to: archive, budget: &budget)
                manifest.overrides[index].destination = .file(destination)
            } else {
                try addDirectory(destination, to: archive, budget: &budget)
                try addChildren(of: source, path: destination, to: archive, budget: &budget)
                manifest.overrides[index].destination = .directory(destination)
            }
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let data = try encoder.encode(manifest)
        guard UInt64(data.count) <= MapLocalBundleZIPStructure.maximumManifestBytes else {
            throw MapLocalBundleError.resourceLimit("manifest.json exceeds 4 MiB.")
        }
        try budget.add(size: UInt64(data.count))
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(data.count), compressionMethod: .deflate) {
            position, size in data.subdata(in: Int(position)..<min(Int(position) + size, data.count))
        }
        // Validate the complete temporary ZIP before replacing an authorized destination.
        // rename(2) is a same-directory atomic replacement, with no remove-and-copy gap.
        _ = try validatedArchive(at: temporary)
        guard Darwin.rename(temporary.path, archiveURL.path) == 0 else {
            throw POSIXError(POSIXErrorCode(rawValue: errno) ?? .EIO)
        }
    }

    private struct Item {
        let entry: Entry
        let path: String
        let record: MapLocalBundleZIPStructure.Record
    }

    private struct Validated {
        let archive: Archive
        let items: [Item]
        let manifest: MapLocalBundleManifest
    }

    private static func validatedArchive(at url: URL) throws -> Validated {
        let structure = try MapLocalBundleZIPStructure(url: url)
        let archive = try Archive(url: url, accessMode: .read)
        let entries = Array(archive)
        guard entries.count == structure.records.count else {
            throw MapLocalBundleError.invalidArchive("One or more ZIP entries are unreadable.")
        }
        var items: [Item] = []
        var paths: [String: Bool] = [:]
        var directories = Set<String>()
        var exactDirectories = Set<String>()
        var exactFiles = Set<String>()
        for (entry, record) in zip(entries, structure.records) {
            let isDirectory = entry.type == .directory
            guard entry.type != .symlink, isDirectory == record.directory,
                  entry.checksum == record.checksum,
                  entry.compressedSize == record.compressedSize,
                  entry.uncompressedSize == record.uncompressedSize else {
                throw MapLocalBundleError.invalidArchive("Entry metadata is inconsistent for '\(entry.path)'.")
            }
            try validatePath(entry.path, directory: isDirectory)
            let path = isDirectory ? String(entry.path.dropLast()) : entry.path
            guard path == "manifest.json" || path == "map-local" || path.hasPrefix("map-local/") else {
                throw MapLocalBundleError.invalidArchive("Unexpected entry '\(path)'; resources belong under map-local/.")
            }
            guard path != "map-local" || isDirectory, path != "manifest.json" || !isDirectory else {
                throw MapLocalBundleError.invalidArchive("Invalid manifest or resource root type.")
            }
            let key = pathKey(path)
            guard paths.updateValue(isDirectory, forKey: key) == nil else {
                throw MapLocalBundleError.invalidArchive("Duplicate or filesystem-equivalent path '\(path)'.")
            }
            let components = key.split(separator: "/")
            for count in 1..<components.count { directories.insert(components.prefix(count).joined(separator: "/")) }
            if isDirectory { directories.insert(key) }
            let exactComponents = path.split(separator: "/")
            for count in 1..<exactComponents.count { exactDirectories.insert(exactComponents.prefix(count).joined(separator: "/")) }
            if isDirectory { exactDirectories.insert(path) } else { exactFiles.insert(path) }
            items.append(Item(entry: entry, path: path, record: record))
        }
        for (path, directory) in paths where !directory && directories.contains(path) {
            throw MapLocalBundleError.invalidArchive("File '\(path)' is also the parent of another entry.")
        }
        guard let manifestItem = items.first(where: { $0.path == "manifest.json" }) else {
            throw MapLocalBundleError.invalidArchive("Missing manifest.json.")
        }
        guard manifestItem.record.uncompressedSize <= MapLocalBundleZIPStructure.maximumManifestBytes else {
            throw MapLocalBundleError.resourceLimit("manifest.json exceeds 4 MiB.")
        }
        var manifestData = Data()
        try read(manifestItem, from: archive) { manifestData.append($0) }
        let manifest: MapLocalBundleManifest
        do { manifest = try JSONDecoder().decode(MapLocalBundleManifest.self, from: manifestData) }
        catch { throw MapLocalBundleError.invalidArchive("manifest.json does not match the Map Local rule schema: \(error.localizedDescription)") }
        try validateRules(manifest)
        for rule in manifest.overrides {
            let path = rule.destination.path
            try validatePath(path, directory: !rule.destination.isFile)
            guard path.hasPrefix("map-local/") else {
                throw MapLocalBundleError.invalidRule("'\(rule.displayName)' destination must be relative and under map-local/.")
            }
            let lookupPath = path.hasSuffix("/") ? String(path.dropLast()) : path
            let key = pathKey(lookupPath)
            if rule.destination.isFile {
                guard paths[key] == false, exactFiles.contains(path) else {
                    throw MapLocalBundleError.invalidRule("Missing response file '\(path)'.")
                }
            } else {
                guard directories.contains(key), paths[key] != false,
                      exactDirectories.contains(lookupPath) else {
                    throw MapLocalBundleError.invalidRule("Missing response directory '\(path)'.")
                }
            }
        }
        let directFilePaths = Set(manifest.overrides.filter { $0.destination.isFile }.map { $0.destination.path })
        for item in items where item.path != "manifest.json" && item.entry.type == .file {
            let isDirectFile = directFilePaths.contains(item.path)
            var probe = PointerProbe()
            try read(item, from: archive) { chunk in
                if isDirectFile && probe.consume(chunk) {
                    throw MapLocalBundleError.invalidArchive("External FILE_URL pointer in '\(item.path)'; export resolved response bytes instead.")
                }
            }
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
                    throw MapLocalBundleError.invalidArchive("Expanded data exceeds the declared size for '\(item.path)'.")
                }
                try consumer(data)
            }
        } catch let error as MapLocalBundleError { throw error }
        catch { throw MapLocalBundleError.invalidArchive("Cannot read '\(item.path)': \(error.localizedDescription)") }
        guard count == item.record.uncompressedSize, checksum == item.record.checksum else {
            throw MapLocalBundleError.invalidArchive("Size or CRC checksum mismatch for '\(item.path)'.")
        }
    }

    private static func validateRules(_ manifest: MapLocalBundleManifest) throws {
        guard manifest.formatVersion == 1 else { throw MapLocalBundleError.unsupportedVersion(manifest.formatVersion) }
        guard !manifest.name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            throw MapLocalBundleError.invalidArchive("Bundle name must not be blank.")
        }
        var ids = Set<UUID>()
        for rule in manifest.overrides {
            guard ids.insert(rule.id).inserted else { throw MapLocalBundleError.invalidRule("Duplicate rule UUID \(rule.id).") }
            guard !rule.url.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw MapLocalBundleError.invalidRule("'\(rule.displayName)' has an empty URL pattern.")
            }
            if rule.matchStyle == .regex {
                do { _ = try NSRegularExpression(pattern: rule.url, options: [.caseInsensitive]) }
                catch { throw MapLocalBundleError.invalidRule("'\(rule.displayName)' has an invalid regular expression: \(error.localizedDescription)") }
            }
            let token = CharacterSet(charactersIn: "!#$%&'*+-.^_`|~0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz")
            guard rule.method.isAny || rule.method.displayName.unicodeScalars.allSatisfy({ token.contains($0) }) else {
                throw MapLocalBundleError.invalidRule("'\(rule.displayName)' has an invalid HTTP method token.")
            }
            guard rule.responseDelay.isFinite, rule.responseDelay >= 0 else {
                throw MapLocalBundleError.invalidRule("'\(rule.displayName)' delay must be finite and nonnegative.")
            }
            guard !rule.destination.path.isEmpty else { throw MapLocalBundleError.invalidRule("'\(rule.displayName)' has no response destination.") }
        }
    }

    private static func validatePath(_ path: String, directory: Bool) throws {
        guard !path.isEmpty, path.utf8.count <= 1_024, !path.hasPrefix("/"),
              !path.contains("\\"), !path.contains(":"),
              !path.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }),
              !path.hasSuffix("/") || directory else {
            throw MapLocalBundleError.invalidArchive("Unsafe archive path '\(path)'.")
        }
        let normalized = directory && path.hasSuffix("/") ? String(path.dropLast()) : path
        let parts = normalized.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.allSatisfy({ !$0.isEmpty && $0 != "." && $0 != ".." && $0.utf8.count <= 255 }) else {
            throw MapLocalBundleError.invalidArchive("Unsafe archive path '\(path)'.")
        }
    }

    private static func pathKey(_ path: String) -> String {
        path.folding(options: .caseInsensitive, locale: Locale(identifier: "en_US_POSIX"))
            .precomposedStringWithCanonicalMapping
    }

    private static func withSnapshot<T>(of url: URL, body: (URL) throws -> T) throws -> T {
        guard url.isFileURL else { throw MapLocalBundleError.invalidArchive("Bundle input must be a local ZIP file.") }
        let manager = FileManager.default
        let attributes = try manager.attributesOfItem(atPath: url.path)
        guard attributes[.type] as? FileAttributeType == .typeRegular else {
            throw MapLocalBundleError.invalidArchive("Bundle input is not a regular ZIP file.")
        }
        guard ((attributes[.size] as? NSNumber)?.uint64Value ?? UInt64.max) <= MapLocalBundleZIPStructure.maximumArchiveBytes else {
            throw MapLocalBundleError.resourceLimit("ZIP exceeds 1 GiB plus metadata.")
        }
        let temporary = manager.temporaryDirectory.appendingPathComponent("bundle-read-\(UUID().uuidString)", isDirectory: true)
        try manager.createDirectory(at: temporary, withIntermediateDirectories: false)
        defer { try? manager.removeItem(at: temporary) }
        let snapshot = temporary.appendingPathComponent("bundle.zip")
        try manager.copyItem(at: url, to: snapshot)
        let snapshotAttributes = try manager.attributesOfItem(atPath: snapshot.path)
        guard snapshotAttributes[.type] as? FileAttributeType == .typeRegular else {
            throw MapLocalBundleError.invalidArchive("Bundle input changed to a non-regular file while being copied.")
        }
        return try body(snapshot)
    }

    private struct ExportBudget {
        var count = 0
        var bytes: UInt64 = 0

        mutating func add(size: UInt64) throws {
            count += 1
            bytes += size
            guard count <= MapLocalBundleZIPStructure.maximumEntries,
                  size <= MapLocalBundleZIPStructure.maximumFileBytes,
                  bytes <= MapLocalBundleZIPStructure.maximumTotalBytes else {
                throw MapLocalBundleError.resourceLimit("Export permits 10,000 entries, 512 MiB per file, and 1 GiB total.")
            }
        }
    }

    private static func sourceType(_ source: URL) throws -> FileAttributeType {
        let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
        guard let type = attributes[.type] as? FileAttributeType, type == .typeRegular || type == .typeDirectory else {
            throw MapLocalBundleError.invalidRule("Only regular response files and directories can be exported: \(source.path)")
        }
        return type
    }

    private static func addDirectory(_ path: String, to archive: Archive, budget: inout ExportBudget) throws {
        try validatePath(path, directory: false)
        try budget.add(size: 0)
        try archive.addEntry(with: path + "/", type: .directory, uncompressedSize: Int64(0)) { _, _ in Data() }
    }

    private static func addChildren(of source: URL, path: String, to archive: Archive, budget: inout ExportBudget) throws {
        let children = try FileManager.default.contentsOfDirectory(at: source, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let childPath = path + "/" + child.lastPathComponent
            try validatePath(childPath, directory: false)
            if try sourceType(child) == .typeDirectory {
                try addDirectory(childPath, to: archive, budget: &budget)
                try addChildren(of: child, path: childPath, to: archive, budget: &budget)
            } else {
                try addFile(child, path: childPath, resolvePointers: false, to: archive, budget: &budget)
            }
        }
    }

    private static func addFile(_ source: URL, path: String, resolvePointers: Bool, to archive: Archive, budget: inout ExportBudget) throws {
        _ = try sourceType(source)
        let handle = try FileHandle(forReadingFrom: source)
        defer { try? handle.close() }
        let size = try handle.seekToEnd()
        guard size <= MapLocalBundleZIPStructure.maximumFileBytes else {
            throw MapLocalBundleError.resourceLimit("Response file exceeds 512 MiB: \(source.path)")
        }
        try handle.seek(toOffset: 0)
        var probe = PointerProbe()
        var isPointer = false
        while resolvePointers && !probe.finished {
            let chunk = try handle.read(upToCount: 16 * 1_024) ?? Data()
            if chunk.isEmpty { break }
            if probe.consume(chunk) { isPointer = true; break }
        }
        if isPointer {
            try handle.seek(toOffset: 0)
            let data = try handle.readToEnd() ?? Data()
            let response: HTTPResponse
            if let reference = MapLocalResponder.fileReference(in: data) {
                let referenced = MapLocalResponder.expand(reference)
                guard try sourceType(referenced) == .typeRegular else {
                    throw MapLocalBundleError.invalidRule("FILE_URL does not point to a regular file: \(referenced.path)")
                }
                let referenceSize = (try FileManager.default.attributesOfItem(atPath: referenced.path)[.size] as? NSNumber)?.uint64Value ?? UInt64.max
                guard referenceSize <= MapLocalBundleZIPStructure.maximumFileBytes else {
                    throw MapLocalBundleError.resourceLimit("FILE_URL response exceeds 512 MiB.")
                }
                let payload = try Data(contentsOf: referenced)
                response = MapLocalResponder.makeResponse(from: payload, pathExtension: referenced.pathExtension)
            } else {
                response = MapLocalResponder.makeResponse(from: data, pathExtension: source.pathExtension)
            }
            // Framing preserves MIME inference and literal pointer-like response bodies.
            var materialized = Data("\(response.httpVersion) \(response.statusCode) \(response.statusText)\r\n".utf8)
            for header in response.headers.entries {
                materialized.append(contentsOf: "\(header.name): \(header.value)\r\n".utf8)
            }
            materialized.append(contentsOf: "\r\n".utf8)
            materialized.append(response.body)
            try budget.add(size: UInt64(materialized.count))
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(materialized.count), compressionMethod: .deflate) {
                position, count in materialized.subdata(in: Int(position)..<min(Int(position) + count, materialized.count))
            }
        } else {
            try budget.add(size: size)
            try handle.seek(toOffset: 0)
            try archive.addEntry(with: path, type: .file, uncompressedSize: Int64(size), compressionMethod: .deflate) {
                _, count in try handle.read(upToCount: count) ?? Data()
            }
        }
    }

    private struct PointerProbe {
        private var pending: [UInt8] = []
        private var prefixIndex = 0
        private var skippingWhitespace = true
        private(set) var finished = false
        private static let prefix = Array("<FILE_URL=".utf8)

        mutating func consume(_ data: Data) -> Bool {
            guard !finished else { return false }
            for byte in data {
                if skippingWhitespace {
                    pending.append(byte)
                    let first = pending[0]
                    let length = first < 0x80 ? 1 : first & 0xe0 == 0xc0 ? 2 : first & 0xf0 == 0xe0 ? 3 : first & 0xf8 == 0xf0 ? 4 : 1
                    if pending.count < length { continue }
                    let scalar = String(bytes: pending, encoding: .utf8)?.unicodeScalars.first
                    if let scalar, CharacterSet.whitespacesAndNewlines.contains(scalar) {
                        pending.removeAll(keepingCapacity: true)
                        continue
                    }
                    skippingWhitespace = false
                    guard pending.count == 1, pending[0] == Self.prefix[0] else { finished = true; return false }
                    prefixIndex = 1
                    pending.removeAll(keepingCapacity: true)
                } else {
                    guard byte == Self.prefix[prefixIndex] else { finished = true; return false }
                    prefixIndex += 1
                    if prefixIndex == Self.prefix.count { finished = true; return true }
                }
            }
            return false
        }
    }
}
