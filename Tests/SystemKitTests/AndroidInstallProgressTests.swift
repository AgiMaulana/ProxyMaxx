import XCTest
@testable import SystemKit

/// The guide's step counter is read from the installer's own numbered lines, so these check
/// the reading rules: what counts as a phase, what does not, and where six phases end.
final class AndroidInstallProgressTests: XCTestCase {
    private func progress(_ lines: [String]) -> AndroidInstallProgress {
        AndroidInstallProgress(log: lines)
    }

    func testNoOutputIsBeforeTheFirstStep() {
        let value = progress([])
        XCTAssertEqual(value.completed, 0)
        XCTAssertEqual(value.label, "android.emulator.phase.starting")
    }

    func testTheLastNumberedLineIsTheStepInProgress() {
        let value = progress([
            "1. Checking for devices...",
            "✅ Found: emulator-5554",
            "",
            "3. Installing the ProxyMaxx certificate as a system CA…"
        ])
        XCTAssertEqual(value.completed, 3)
        XCTAssertEqual(value.total, 6)
        XCTAssertEqual(value.label, "android.emulator.phase.certificate")
    }

    func testTheScriptsOwnDoneMarksTheLastStep() {
        let value = progress([
            "1. Checking for devices...",
            "5. Launching the tunnel app…",
            "✓ Launched",
            "✅ Done"
        ])
        XCTAssertEqual(value.completed, 6)
    }

    /// Help text prints indented numbered lists. Those are recovery advice, not progress, and
    /// counting them would jump the bar to the end on the first failure.
    func testIndentedAdviceIsNotAPhase() {
        let value = progress([
            "❌ No device or emulator is connected.",
            "       1) Android Studio → Tools → Device Manager",
            "   • Or create an emulator from a system image"
        ])
        XCTAssertEqual(value.completed, 0)
    }

    func testRepeatingAPhaseDoesNotMoveBackwards() {
        let value = progress(["4. Installing the ProxyMaxx tunnel app…", "2. Clearing the HTTP proxy"])
        XCTAssertEqual(value.completed, 4)
    }

    /// A phase the script gains later still shows up as a step, not as a wrong name.
    func testEveryStepHasALabel() {
        for step in 1...AndroidInstallProgress.total {
            XCTAssertFalse(AndroidInstallProgress.label(for: step).isEmpty)
        }
    }
}
