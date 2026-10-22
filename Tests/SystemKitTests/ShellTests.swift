import XCTest
@testable import SystemKit

/// The Android installer asks for consent on standard input, so the runner has to be able to
/// deliver an answer. Without it the helper reads end of file and cancels the setup.
final class ShellTests: XCTestCase {
    func testStdinIsDeliveredToTheCommand() throws {
        let result = try Shell.run(
            "/bin/sh",
            ["-c", #"IFS= read -t 5 -r answer; printf '%s' "$answer""#],
            stdin: "yes\n"
        )

        XCTAssertEqual(result.status, 0)
        XCTAssertEqual(result.output, "yes")
    }

    /// An empty answer is still a pipe that closes, which is the end of file the helper used to
    /// see on every run.
    func testAnEmptyAnswerReachesTheCommandAsEndOfFile() throws {
        let result = try Shell.run(
            "/bin/sh",
            ["-c", #"IFS= read -t 1 -r answer; printf '[%s]' "$answer""#],
            stdin: ""
        )

        XCTAssertEqual(result.output, "[]")
    }

    /// A failing script reports its status instead of aborting the caller, which is what lets
    /// the app read the log and show the real reason.
    func testANonZeroExitIsReportedRatherThanThrown() throws {
        let result = try Shell.run("/bin/sh", ["-c", "exit 10"])

        XCTAssertEqual(result.status, 10)
        XCTAssertFalse(result.succeeded)
    }
}
