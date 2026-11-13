import Foundation
import XCTest
import ZIPFoundation
@testable import PluginKit

/// Every test works inside its own temp directory so a real Application Support
/// record can never leak into them.
extension XCTestCase {
    func makeTempDirectory(function: String = #function) -> URL {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("PluginKitTests-\(function)-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        return url
    }

    func waitForFile(_ url: URL, timeout: TimeInterval = 10) throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            Thread.sleep(forTimeInterval: 0.05)
        }
        XCTFail("Timed out waiting for \(url.path)")
        return Data()
    }

    /// Suspends between polls so the main actor stays free — the plugin runner and
    /// permission manager do their work on the main actor, so a blocking poll on the
    /// test thread would deadlock the very pipeline under test.
    func waitForFileAsync(_ url: URL, timeout: TimeInterval = 10) async throws -> Data {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let data = try? Data(contentsOf: url), !data.isEmpty { return data }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        XCTFail("Timed out waiting for \(url.path)")
        return Data()
    }

    func waitUntilAsync(_ predicate: @autoclosure @escaping () -> Bool, timeout: TimeInterval = 5) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if predicate() { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return predicate()
    }
}

/// Builds `.pxplugin` packages in code — no checked-in fixtures.
enum PluginFixtures {
    static func manifest(
        id: String = "com.example.test-plugin",
        version: String = "1.0.0",
        sdkVersion: String = "^1.0.0",
        permissions: [PluginManifest.PermissionDeclaration] = [
            PluginManifest.PermissionDeclaration(
                id: "local-map.create", required: true, reason: "Create mapping rules."
            )
        ],
        entryPoint: String = "entrypoint.sh"
    ) -> PluginManifest {
        PluginManifest(
            id: id,
            name: "Test Plugin",
            version: version,
            description: "A plugin built for tests.",
            author: "ProxyMaxx Tests",
            sdkVersion: sdkVersion,
            permissions: permissions,
            entryPoint: entryPoint
        )
    }

    struct Package {
        var manifest: PluginManifest
        /// nil omits the entry point from the package entirely.
        var entryPointContents: String?
        var resources: [String: String] = [:]
    }

    /// Write the package to `destinationURL` as a `.pxplugin` ZIP.
    @discardableResult
    static func makePackage(_ package: Package, to destinationURL: URL) throws -> URL {
        let staging = destinationURL.deletingLastPathComponent()
            .appendingPathComponent("staging-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: staging) }

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        try encoder.encode(package.manifest).write(to: staging.appendingPathComponent("manifest.json"))

        if let contents = package.entryPointContents {
            let entryPoint = staging.appendingPathComponent(package.manifest.entryPoint)
            try FileManager.default.createDirectory(
                at: entryPoint.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: entryPoint, atomically: true, encoding: .utf8)
        }
        for (relativePath, contents) in package.resources {
            let resource = staging.appendingPathComponent("resources").appendingPathComponent(relativePath)
            try FileManager.default.createDirectory(
                at: resource.deletingLastPathComponent(), withIntermediateDirectories: true
            )
            try contents.write(to: resource, atomically: true, encoding: .utf8)
        }

        let archive = try Archive(url: destinationURL, accessMode: .create)
        try addTree(root: staging, directory: staging, entryPrefix: "", into: archive)
        return destinationURL
    }

    /// Walk the staging tree and add each entry under its staging-relative name.
    /// Names come from `lastPathComponent`, so no absolute-path slicing is involved.
    private static func addTree(root: URL, directory: URL, entryPrefix: String, into archive: Archive) throws {
        let children = try FileManager.default
            .contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
            .sorted { $0.lastPathComponent < $1.lastPathComponent }
        for child in children {
            let entryPath = entryPrefix.isEmpty ? child.lastPathComponent : entryPrefix + "/" + child.lastPathComponent
            var isDirectory: ObjCBool = false
            FileManager.default.fileExists(atPath: child.path, isDirectory: &isDirectory)
            if isDirectory.boolValue {
                try addTree(root: root, directory: child, entryPrefix: entryPath, into: archive)
            } else {
                try archive.addEntry(with: entryPath, relativeTo: root)
            }
        }
    }

    /// The canonical stub plugin for runner tests: request one permission, wait for
    /// the response line, write it to the file named by argv[1].
    static func permissionProbeScript(permissionID: String) -> String {
        // Protocol v1: every request carries a requestId.
        """
        #!/bin/sh
        printf '{"kind":"permission.request","requestId":"probe-1","permissionId":"\(permissionID)"}\\n'
        IFS= read -r response
        printf '%s' "$response" > "$1"
        """
    }
}

/// Secret storage that never touches the Keychain.
final class InMemorySecrets: SecretProviding, @unchecked Sendable {
    private var storage: [String: Data] = [:]
    private let lock = NSLock()

    func data(forKey account: String) throws -> Data? {
        lock.lock(); defer { lock.unlock() }
        return storage[account]
    }

    func store(_ data: Data, forKey account: String) throws {
        lock.lock(); defer { lock.unlock() }
        storage[account] = data
    }
}
