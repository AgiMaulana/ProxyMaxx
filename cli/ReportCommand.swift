import Foundation
import LogKit

/// `proxymaxx-cli report` — hand the newest logs to a prefilled GitHub issue.
///
/// Bare form prints the tail of `0.log` so an agent can read it without opening a
/// browser. `--open` opens the prefilled new-issue page. `--print` prints the
/// issue URL itself, for scripts that want to post or inspect it.
enum ReportCommand {
    static func run(_ arguments: Arguments) {
        if arguments.has("print") {
            guard let url = IssueReporter.issueURL() else {
                fail("could not build an issue URL")
            }
            print(url.absoluteString)
            return
        }
        if arguments.has("open") {
            guard IssueReporter.openIssuePage() else {
                fail("could not open the prefilled issue page")
            }
            note("opened a prefilled GitHub issue with the latest logs")
            return
        }
        let tail = LogKit.logFile.latestText(maxBytes: LogKit.logFile.maxFileBytes)
        guard let tail, !tail.isEmpty else {
            note("no logs yet at \(LogKit.logFile.url.path)")
            return
        }
        print(tail, terminator: tail.hasSuffix("\n") ? "" : "\n")
    }
}
