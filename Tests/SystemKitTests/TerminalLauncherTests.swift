import XCTest
@testable import SystemKit

/// Covers the parts of the two terminal buttons that can fail without anyone noticing: the
/// script the new window runs, and the quoting that carries it through AppleScript.
final class TerminalLauncherTests: XCTestCase {
    private let directory = "/Applications/ProxyMaxx.app/Contents/Resources"
    private let binary = "'/Applications/ProxyMaxx.app/Contents/Resources/proxymaxx-cli'"

    // MARK: - Session only

    /// The first button must not touch the profile: `--print` is what keeps it to one window.
    func testSessionOnlyUsesPrintAndNotTheWritingForm() {
        let script = TerminalLauncher.setupScript(directory: directory, intent: .thisSessionOnly)

        XCTAssertTrue(script.contains("eval \"$(\(binary) export --print)\""), "script was: \(script)")
        XCTAssertFalse(script.contains("export PATH="), "the bundle delegates rather than duplicating")
    }

    /// Terminal closes a window as soon as its command exits, so the session script has to
    /// end by starting an interactive shell — otherwise the user gets a flash, not a terminal.
    func testSessionOnlyLeavesAnInteractiveShellRunning() {
        let script = TerminalLauncher.setupScript(directory: directory, intent: .thisSessionOnly)

        XCTAssertTrue(script.hasSuffix(TerminalLauncher.interactiveShellStart), "script was: \(script)")
        XCTAssertTrue(TerminalLauncher.interactiveShellStart.contains("-i"))
        XCTAssertTrue(TerminalLauncher.interactiveShellStart.contains("${SHELL:-"))
    }

    func testCheckoutSessionOnlyAddsATemporaryPathEntry() {
        let script = TerminalLauncher.setupScript(directory: "/tmp/checkout/.build/debug", intent: .thisSessionOnly)

        XCTAssertFalse(script.contains("export)"), "a checkout has no bundle to export: \(script)")
        XCTAssertTrue(script.contains("export PATH=\"$PATH:/tmp/checkout/.build/debug\""))
        XCTAssertTrue(script.hasSuffix(TerminalLauncher.interactiveShellStart))
    }

    // MARK: - Permanent

    /// The second button must write the block, so it runs bare `export` and then shows the
    /// commands it just made available.
    func testPermanentRunsTheWritingForm() {
        let script = TerminalLauncher.setupScript(directory: directory, intent: .permanently)

        XCTAssertTrue(script.contains("eval \"$(\(binary) export)\""), "script was: \(script)")
        XCTAssertFalse(script.contains("export --print"), "script was: \(script)")
        XCTAssertFalse(script.contains("export PATH="), "the bundle delegates rather than duplicating")
    }

    /// Permanent mode ends at a normal prompt. `--help` is paged, so a launcher that prints it
    /// as the last command would leave the user inside `less`.
    func testPermanentEndsShownTheAvailableCommands() {
        let script = TerminalLauncher.setupScript(directory: directory, intent: .permanently)

        XCTAssertTrue(script.hasSuffix("--help"), "script was: \(script)")
    }

    func testCheckoutPermanentAddsAPathEntry() {
        let script = TerminalLauncher.setupScript(directory: "/tmp/checkout/.build/debug", intent: .permanently)

        XCTAssertFalse(script.contains("export)"), "a checkout has no bundle to export")
        XCTAssertTrue(script.contains("export PATH=\"$PATH:/tmp/checkout/.build/debug\""))
    }

    // MARK: - Quoting

    /// A space in the bundle path is ordinary (`~/Applications/My Apps`), so the binary is
    /// single-quoted inside the AppleScript string rather than left for the shell to split.
    func testABundlePathWithSpacesIsQuotedOnce() {
        let script = TerminalLauncher.setupScript(
            directory: "/Users/me/Applications/My Apps/ProxyMaxx.app/Contents/Resources",
            intent: .thisSessionOnly
        )

        XCTAssertTrue(
            script.contains("'/Users/me/Applications/My Apps/ProxyMaxx.app/Contents/Resources/proxymaxx-cli'"),
            "script was: \(script)"
        )
    }

    func testBundleDetection() {
        XCTAssertTrue(TerminalLauncher.isBundle(directory))
        XCTAssertFalse(TerminalLauncher.isBundle("/tmp/checkout/.build/debug"))
    }

    func testAppleScriptStringEscapesQuotesAndBackslashes() {
        let quoted = TerminalLauncher.appleScriptString(#"do script "a\b""#)

        XCTAssertEqual(quoted, #"do script \"a\\b\""#)
    }

    /// The AppleScript source is built by interpolation, so a directory containing a quote
    /// must not be able to end the literal and inject a new statement. Removing every
    /// backslash-escaped pair must leave exactly the two delimiters around the window script
    /// plus the two around `Terminal`.
    func testAQuoteInThePathCannotBreakTheAppleScriptLiteral() {
        let script = TerminalLauncher.setupScript(directory: "/tmp/it's \"here\"", intent: .thisSessionOnly)
        let source = TerminalLauncher.appleScriptSource(script: script)

        var remaining = ""
        var characters = Array(source)
        var index = 0
        while index < characters.count {
            if characters[index] == "\\", index + 1 < characters.count,
               characters[index + 1] == "\"" || characters[index + 1] == "\\" {
                index += 2
                continue
            }
            remaining.append(characters[index])
            index += 1
        }

        XCTAssertEqual(remaining.components(separatedBy: "\"").count - 1, 4, "unescaped: \(remaining)")
    }
}
