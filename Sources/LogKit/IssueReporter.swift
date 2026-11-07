import Foundation
import Branding
#if canImport(AppKit)
import AppKit
#endif

/// Builds and opens a prefilled GitHub new-issue page carrying the latest logs.
public enum IssueReporter {
    public static let repositoryURL = "https://github.com/AgiMaulana/ProxyMaxx/issues/new"
    /// GitHub trims very long bodies; keep the report comfortably under the cap.
    public static let maxBodyCharacters = 6_000

    /// The issue body: app identity plus the newest log lines from `0.log`.
    public static func body(
        logFile: RotatingLogFile = LogKit.logFile,
        latestLineCount: Int = 200,
        maxCharacters: Int = maxBodyCharacters
    ) -> String {
        let lines = logFile.latestLines(latestLineCount)
        let header = """
        ### Description

        (What happened?)

        ### Version

        \(versionText)

        ### Latest logs

        ```
        """
        let closing = "\n```"
        let marker = "\n…(truncated, see Logs/0.log for the full tail)"
        let logs = lines.isEmpty ? "_0.log is empty._" : lines.joined(separator: "\n")
        let budget = max(0, maxCharacters - header.count - closing.count - marker.count)
        if logs.count <= budget {
            return header + logs + closing
        }
        return header + String(logs.prefix(budget)) + marker + closing
    }

    /// The prefilled new-issue URL, truncated to a practical body length.
    public static func issueURL(logFile: RotatingLogFile = LogKit.logFile) -> URL? {
        var components = URLComponents(string: repositoryURL)
        components?.queryItems = [
            URLQueryItem(name: "title", value: "Report: \(summaryLine(logFile: logFile))"),
            URLQueryItem(name: "body", value: body(logFile: logFile)),
        ]
        return components?.url
    }

    /// Opens the prefilled page in the default browser. Returns false when the
    /// URL could not be built or the open failed.
    @discardableResult
    public static func openIssuePage(logFile: RotatingLogFile = LogKit.logFile) -> Bool {
        guard let url = issueURL(logFile: logFile) else { return false }
        #if canImport(AppKit)
        return NSWorkspace.shared.open(url)
        #else
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/open")
        process.arguments = [url.absoluteString]
        do {
            try process.run()
            return true
        } catch {
            return false
        }
        #endif
    }

    /// `ProxyMaxx 1.2.3 (build 45)` when bundled, falling back to the display name
    /// alone for the unbundled CLI binary.
    static var versionText: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String
        let build = info?["CFBundleVersion"] as? String
        switch (short, build) {
        case let (short?, build?): return "\(Brand.displayName) \(short) (build \(build))"
        case let (short?, nil): return "\(Brand.displayName) \(short)"
        default: return "\(Brand.displayName) (unbundled)"
        }
    }

    /// A one-line hint of what the newest log entry was, for the issue title.
    /// Drops the leading timestamp/level/component so the title reads as prose.
    private static func summaryLine(logFile: RotatingLogFile) -> String {
        guard let line = logFile.latestLines(1).last else { return "no recent logs" }
        let message = line.split(separator: "]", maxSplits: 2).last.map(String.init) ?? line
        return String(message.trimmingCharacters(in: .whitespaces).prefix(120))
    }
}
