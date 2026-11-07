import Foundation

/// Where an Android setup has got to, read from the installer's own output.
///
/// The script prints five numbered phases (`1. Checking for devices...` … `5. Launching the
/// tunnel app...`) and then `✅ Done`; those six lines are the clock. Nothing here is timed or
/// estimated: if the script has not said it, the step has not happened.
public struct AndroidInstallProgress: Sendable, Equatable {
    /// The step now running, 1-based. Equals `total` once the script has finished.
    public let completed: Int
    public let total: Int
    /// A localization key for the running step, for the guide to name it.
    public let label: String

    public static let total = 6

    /// The step in progress, given the lines received so far.
    public init(log: [String]) {
        var reached = 0
        for line in log {
            if let step = Self.phaseNumber(in: line) {
                reached = max(reached, step)
            }
            if Self.isDone(line) {
                reached = Self.total
            }
        }
        self.init(
            completed: reached,
            total: Self.total,
            // Before the first numbered line the script is still looking for a device.
            label: reached == 0 ? "android.emulator.phase.starting" : Self.label(for: reached)
        )
    }

    init(completed: Int, total: Int, label: String) {
        self.completed = completed
        self.total = total
        self.label = label
    }

    /// `"3. Installing the …"` reads as step 3. Numbered lists the script prints inside help
    /// text are indented, so only a line that starts with the number counts.
    public static func phaseNumber(in line: String) -> Int? {
        guard let dot = line.firstIndex(of: "."), dot > line.startIndex else { return nil }
        let number = line[line.startIndex..<dot]
        guard number.count <= 2, number.allSatisfy(\.isNumber) else { return nil }
        let value = Int(number) ?? 0
        return (1...total).contains(value) ? value : nil
    }

    public static func isDone(_ line: String) -> Bool {
        line.trimmingCharacters(in: .whitespaces) == "✅ Done"
    }

    public static func label(for step: Int) -> String {
        switch step {
        case 1: return "android.emulator.phase.devices"
        case 2: return "android.emulator.phase.proxy"
        case 3: return "android.emulator.phase.certificate"
        case 4: return "android.emulator.phase.tunnelApp"
        case 5: return "android.emulator.phase.launch"
        default: return "android.emulator.phase.done"
        }
    }
}
