import XCTest
@testable import SystemKit

/// `proxymaxx-cli export` edits a file the user owns, so the cases that matter are
/// idempotence, replacing a stale block, and leaving everything outside the markers alone.
final class ShellPathExportTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("shell-path-export-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func profile(_ name: String = ".zshrc", contents: String? = nil) throws -> URL {
        let url = root.appendingPathComponent(name)
        if let contents {
            try FileManager.default.createDirectory(
                at: url.deletingLastPathComponent(),
                withIntermediateDirectories: true
            )
            try contents.write(to: url, atomically: true, encoding: .utf8)
        }
        return url
    }

    func testExportLineAddsTheDirectoryRatherThanTheBinary() {
        let resources = "/Applications/ProxyMaxx.app/Contents/Resources"

        XCTAssertEqual(
            ShellPathExport.exportLine(for: resources, shell: .zsh),
            "export PATH=\"$PATH:/Applications/ProxyMaxx.app/Contents/Resources\""
        )
        XCTAssertEqual(
            ShellPathExport.exportLine(for: resources, shell: .bash),
            "export PATH=\"$PATH:/Applications/ProxyMaxx.app/Contents/Resources\""
        )
        XCTAssertEqual(
            ShellPathExport.exportLine(for: resources, shell: .fish),
            "set -gx PATH $PATH '/Applications/ProxyMaxx.app/Contents/Resources'"
        )
    }

    func testShellDetectionFallsBackToZsh() {
        XCTAssertEqual(ShellPathExport.detectShell(environment: ["SHELL": "/bin/zsh"]), .zsh)
        XCTAssertEqual(ShellPathExport.detectShell(environment: ["SHELL": "/bin/bash"]), .bash)
        XCTAssertEqual(ShellPathExport.detectShell(environment: ["SHELL": "/opt/homebrew/bin/fish"]), .fish)
        XCTAssertEqual(ShellPathExport.detectShell(environment: ["SHELL": "/bin/sh"]), .zsh)
        XCTAssertEqual(ShellPathExport.detectShell(environment: [:]), .zsh)
    }

    func testProfileFilesMatchTheShell() {
        let home = URL(fileURLWithPath: "/Users/example", isDirectory: true)

        XCTAssertEqual(ShellPathExport.profileURL(for: .zsh, homeDirectory: home).path, "/Users/example/.zshrc")
        XCTAssertEqual(ShellPathExport.profileURL(for: .bash, homeDirectory: home).path, "/Users/example/.bash_profile")
        XCTAssertEqual(
            ShellPathExport.profileURL(for: .fish, homeDirectory: home).path,
            "/Users/example/.config/fish/config.fish"
        )
    }

    func testInstallAppendsAMarkedBlockOnlyOnce() throws {
        let url = try profile(contents: "# my shell\nalias ll='ls -l'\n")
        let directory = URL(fileURLWithPath: "/Applications/ProxyMaxx.app/Contents/Resources")

        let first = try ShellPathExport.install(directory: directory, shell: .zsh, profileURL: url)
        XCTAssertTrue(first.changed)

        let afterFirst = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(afterFirst.contains(ShellPathExport.markerBegin))
        XCTAssertTrue(afterFirst.contains(first.exportLine))
        XCTAssertTrue(afterFirst.contains("alias ll='ls -l'"))
        XCTAssertEqual(afterFirst.components(separatedBy: ShellPathExport.markerBegin).count - 1, 1)

        let second = try ShellPathExport.install(directory: directory, shell: .zsh, profileURL: url)
        XCTAssertFalse(second.changed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), afterFirst)
    }

    func testInstallReplacesAStaleBlock() throws {
        let url = try profile()
        let old = URL(fileURLWithPath: "/Applications/ProxyMaxx-old.app/Contents/Resources")
        let new = URL(fileURLWithPath: "/Applications/ProxyMaxx.app/Contents/Resources")

        _ = try ShellPathExport.install(directory: old, shell: .zsh, profileURL: url)
        _ = try ShellPathExport.install(directory: new, shell: .zsh, profileURL: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("ProxyMaxx-old.app"))
        XCTAssertTrue(text.contains(ShellPathExport.exportLine(for: new.path, shell: .zsh)))
        XCTAssertEqual(text.components(separatedBy: ShellPathExport.markerBegin).count - 1, 1)
    }

    func testAnExistingManualLineIsNotDuplicated() throws {
        let directory = "/Applications/ProxyMaxx.app/Contents/Resources"
        let line = ShellPathExport.exportLine(for: directory, shell: .zsh)
        let url = try profile(contents: "# added by hand\n\(line)\n")

        let installation = try ShellPathExport.install(
            directory: URL(fileURLWithPath: directory),
            shell: .zsh,
            profileURL: url
        )

        XCTAssertFalse(installation.changed)
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8).components(separatedBy: line).count - 1, 1)
    }

    func testRemoveDeletesOnlyTheManagedBlock() throws {
        let url = try profile(contents: "# my shell\nalias ll='ls -l'\n")
        let directory = URL(fileURLWithPath: "/Applications/ProxyMaxx.app/Contents/Resources")

        _ = try ShellPathExport.install(directory: directory, shell: .zsh, profileURL: url)
        XCTAssertTrue(try ShellPathExport.remove(profileURL: url))

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains(ShellPathExport.markerBegin))
        XCTAssertFalse(text.contains(directory.path))
        XCTAssertTrue(text.contains("# my shell"))
        XCTAssertTrue(text.contains("alias ll='ls -l'"))
        XCTAssertFalse(try ShellPathExport.remove(profileURL: url))
    }

    func testFishProfileGetsFishSyntax() throws {
        let url = try profile("config.fish")

        let installation = try ShellPathExport.install(
            directory: URL(fileURLWithPath: "/Applications/ProxyMaxx.app/Contents/Resources"),
            shell: .fish,
            profileURL: url
        )

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains(installation.exportLine))
        XCTAssertTrue(text.contains("set -gx PATH"))
        XCTAssertFalse(text.contains("export PATH="))
    }

    /// The profile block is one export line. A pruning line was removed because zsh's
    /// `${PATH//…/…}` also rewrote the neighbours it matched, so this stays a single line.
    func testScriptLinesHoldOnlyTheExport() {
        let directory = "/Applications/ProxyMaxx.app/Contents/Resources"

        for shell in ShellPathExport.Shell.allCases {
            XCTAssertEqual(
                ShellPathExport.scriptLines(for: directory, shell: shell),
                [ShellPathExport.exportLine(for: directory, shell: shell)]
            )
        }
    }

    func testPathsWithSpecialCharactersAreQuoted() {
        let directory = "/Users/me/My $Apps/ProxyMaxx's /Resources"

        XCTAssertEqual(
            ShellPathExport.exportLine(for: directory, shell: .zsh),
            "export PATH=\"$PATH:/Users/me/My \\$Apps/ProxyMaxx's /Resources\""
        )
        XCTAssertEqual(
            ShellPathExport.exportLine(for: directory, shell: .fish),
            "set -gx PATH $PATH '/Users/me/My $Apps/ProxyMaxx\\'s /Resources'"
        )
    }
}
