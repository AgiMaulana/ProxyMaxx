import Foundation
import Branding

// MARK: - What the latest release says

/// The newest published release, as far as the app needs it: which version, and where the
/// user can read about it. Everything else in the GitHub payload is ignored on purpose —
/// the release notes are a web page, not text the app renders.
public struct LatestRelease: Equatable, Sendable {
    public let tagName: String
    public let version: ReleaseVersion
    public let pageURL: URL
    public let dmgURL: URL?

    public init(tagName: String, version: ReleaseVersion, pageURL: URL, dmgURL: URL?) {
        self.tagName = tagName
        self.version = version
        self.pageURL = pageURL
        self.dmgURL = dmgURL
    }
}

/// Reads the latest release out of the payload GitHub serves for
/// `GET /repos/{owner}/{repo}/releases/latest`.
///
/// The endpoint already excludes drafts and prereleases, so a tag that does not parse is a
/// broken release rather than one this app should ignore: it fails the parse and the caller
/// keeps whatever it knew before.
public enum LatestReleasePayload {
    public static let expectedHostSuffix = "github.com"

    public static func release(from data: Data) throws -> LatestRelease {
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw UpdateCheckError.malformedResponse("the release is not a JSON object")
        }
        guard let tag = object["tag_name"] as? String, let version = ReleaseVersion(tag) else {
            throw UpdateCheckError.malformedResponse("the release has no parsable tag_name")
        }
        guard let page = (object["html_url"] as? String).flatMap(URL.init(string:)),
              page.scheme == "https",
              page.host?.hasSuffix(expectedHostSuffix) == true else {
            throw UpdateCheckError.malformedResponse("the release has no GitHub html_url")
        }
        let dmg = (object["assets"] as? [[String: Any]])?
            .first { ($0["name"] as? String)?.hasSuffix(".dmg") == true }
            .flatMap { $0["browser_download_url"] as? String }
            .flatMap(URL.init(string:))
        return LatestRelease(tagName: tag, version: version, pageURL: page, dmgURL: dmg)
    }

    /// The last payload that parsed, kept across launches so a launch that cannot reach
    /// GitHub still knows which release is current.
    public static func remember(_ data: Data, directory: URL = cacheDirectory) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        try data.write(to: directory.appendingPathComponent(cacheFileName), options: .atomic)
    }

    public static func cachedRelease(directory: URL = cacheDirectory) -> LatestRelease? {
        let file = directory.appendingPathComponent(cacheFileName)
        guard let data = try? Data(contentsOf: file) else { return nil }
        return try? release(from: data)
    }

    public static var cacheFileName: String { "latest-release.json" }
    public static var cacheDirectory: URL {
        Brand.supportDirectory.appendingPathComponent("Updates", isDirectory: true)
    }
}

// MARK: - Versions

/// A `MAJOR.MINOR.PATCH` release tag, compared numerically. A leading `v` is accepted
/// because the repository tags releases that way; a pre-release suffix is refused, since a
/// prerelease never reaches `/releases/latest` and an installed one cannot be compared
/// meaningfully against a stable release.
public struct ReleaseVersion: Equatable, Comparable, Sendable, CustomStringConvertible {
    public let major: Int
    public let minor: Int
    public let patch: Int

    public init(major: Int, minor: Int, patch: Int) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// `v0.5.0`, `0.5.0`, `0.5` — anything else is nil rather than a guess.
    public init?(_ text: String) {
        var body = Substring(text.trimmingCharacters(in: .whitespacesAndNewlines))
        if body.hasPrefix("v") || body.hasPrefix("V") { body = body.dropFirst() }
        let parts = body.split(separator: ".", omittingEmptySubsequences: false)
        guard (2...3).contains(parts.count),
              let major = Int(parts[0]),
              let minor = Int(parts[1]),
              major >= 0, minor >= 0
        else { return nil }
        let patch = parts.count == 3 ? Int(parts[2]) : 0
        guard let patch, patch >= 0 else { return nil }
        self.init(major: major, minor: minor, patch: patch)
    }

    public var description: String { "\(major).\(minor).\(patch)" }

    public static func < (lhs: ReleaseVersion, rhs: ReleaseVersion) -> Bool {
        (lhs.major, lhs.minor, lhs.patch) < (rhs.major, rhs.minor, rhs.patch)
    }
}

/// The version this copy of ProxyMaxx is. Read from the bundle, so it is the stamped release
/// tag in a downloaded app and `0.0.0` for an unbundled `swift run`, which never claims to be
/// newer than a release. `CFBundleShortVersionString` is what the release workflow stamps from
/// the tag.
public enum InstalledVersion {
    public static func version(bundle: Bundle = .main) -> ReleaseVersion? {
        (bundle.infoDictionary?["CFBundleShortVersionString"] as? String)
            .flatMap(ReleaseVersion.init)
    }

    /// Non-nil only for a bundled app whose version parses. An unbundled build is not an
    /// installation, so it is never offered an update.
    public static func comparableVersion(bundle: Bundle = .main) -> ReleaseVersion? {
        guard bundle.bundleIdentifier != nil else { return nil }
        return version(bundle: bundle)
    }
}

// MARK: - How this copy was installed

/// Which install path the user took, because it decides the upgrade the balloon can offer.
/// The Homebrew cask lives in its own tap, so the tap has to be named in the command.
public enum InstallOrigin: String, Equatable, Sendable {
    /// `brew install --cask AgiMaulana/proxymaxx/proxymaxx`: the cask owns the app.
    case homebrew
    /// Dragged out of the DMG. There is no package manager to ask, so the balloon hands the
    /// user the command to copy.
    case directDownload
    /// `swift build`, `Scripts/run.sh`, or a checkout's `dist/`. Never prompted.
    case development
}

/// Decides `InstallOrigin` from where the app runs and what Homebrew leaves behind.
///
/// A cask installs the app to `/Applications/ProxyMaxx.app` and keeps a Caskroom entry that
/// *symlinks to* that copy. So the app's own path only proves "installed to /Applications",
/// which a DMG drag also produces; the Caskroom entry is what distinguishes the two.
public enum InstallOriginDetector {
    /// The cask's fully qualified name. `brew` resolves the tap from it, so a tap installed
    /// under a different local name still upgrades the app this copy came from.
    public static let caskReference = "AgiMaulana/proxymaxx/proxymaxx"
    /// The cask's token, which is the Caskroom directory name.
    public static let caskToken = "proxymaxx"
    public static let appBundleName = "ProxyMaxx.app"
    /// Where the cask installs the app to.
    public static let applicationsDirectory = "/Applications"

    /// Homebrew's prefix depends on the Mac: `/opt/homebrew` on Apple silicon, `/usr/local`
    /// on Intel. Both are checked because a Homebrew directory can be carried between them.
    public static var caskroomDirectories: [URL] {
        [
            URL(fileURLWithPath: "/opt/homebrew/Caskroom", isDirectory: true),
            URL(fileURLWithPath: "/usr/local/Caskroom", isDirectory: true),
        ]
    }

    public static func origin(
        bundleURL: URL,
        applicationsDirectory: String = InstallOriginDetector.applicationsDirectory,
        caskroomDirectories: [URL]? = nil,
        fileManager: FileManager = .default
    ) -> InstallOrigin {
        let caskrooms = caskroomDirectories ?? self.caskroomDirectories
        let path = bundleURL.standardizedFileURL.path
        let installsToApplications = path.hasPrefix(applicationsDirectory + "/")
        let insideCaskroom = caskrooms.contains { path.hasPrefix($0.path + "/") }
        guard installsToApplications || insideCaskroom else {
            // `Scripts/run.sh`, `.build/`, or a checkout's `dist/`: never an installation.
            return .development
        }

        for caskroom in caskrooms {
            if caskAppLinks(to: bundleURL, caskroom: caskroom, fileManager: fileManager) {
                return .homebrew
            }
        }
        return .directDownload
    }

    /// True when the Caskroom holds this cask and its app points at the running bundle.
    ///
    /// The link is the proof, not just the directory's presence: a leftover Caskroom entry
    /// must not make a DMG copy look like a cask install, because the offered upgrade would
    /// then replace whichever copy the link names.
    public static func caskAppLinks(
        to bundleURL: URL,
        caskroom: URL,
        fileManager: FileManager = .default
    ) -> Bool {
        let base = caskroom.appendingPathComponent(caskToken, isDirectory: true)
        guard let versions = try? fileManager.contentsOfDirectory(
            at: base,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        ) else { return false }
        let running = bundleURL.standardizedFileURL.resolvingSymlinksInPath().path
        for version in versions {
            let installed = version.appendingPathComponent(appBundleName)
            guard fileManager.fileExists(atPath: installed.path) else { continue }
            let resolved = installed.resolvingSymlinksInPath().standardizedFileURL.path
            if resolved == running || resolved == bundleURL.standardizedFileURL.path {
                return true
            }
        }
        return false
    }
}

// MARK: - The check itself

public enum UpdateCheckError: Error, Equatable, LocalizedError {
    /// The endpoint answered, but not with a release this app can read.
    case malformedResponse(String)
    /// The network, TLS, or HTTP layer failed.
    case transport(String)

    public var errorDescription: String? {
        switch self {
        case .malformedResponse(let reason): return "Unreadable release: \(reason)"
        case .transport(let reason): return "Update check failed: \(reason)"
        }
    }
}

/// Calls GitHub's public API for the newest release.
///
/// Unauthenticated, like any other GitHub API client: 60 requests per hour per address is
/// why the check is throttled to once a day. The request is what asks macOS for network
/// access, so the firewall prompt lands on first launch, while the app is in front of the
/// user, rather than on an upgrade in the middle of the session.
public final class GitHubUpdateChecker: @unchecked Sendable {
    public static let owner = "AgiMaulana"
    public static let repository = "ProxyMaxx"

    public var latestReleaseURL: URL {
        URL(string: "https://api.github.com/repos/\(Self.owner)/\(Self.repository)/releases/latest")!
    }

    private let session: URLSession

    public init(session: URLSession? = nil) {
        let configuration = URLSessionConfiguration.ephemeral
        // The cache would serve a release the user already upgraded past, and the check is
        // already rate-limited by the caller.
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.timeoutIntervalForRequest = 15
        configuration.timeoutIntervalForResource = 30
        self.session = session ?? URLSession(configuration: configuration)
    }

    public func fetchLatestRelease() async throws -> LatestRelease {
        do {
            return try await requestLatestRelease()
        } catch let error as UpdateCheckError {
            // A launch that races the network (the first one also waits on the firewall
            // prompt) must not fail forever: a release already read off the wire is still a
            // valid answer, so it is used once. A malformed answer is not cached, so a bad
            // release cannot be served from here.
            guard let cached = LatestReleasePayload.cachedRelease() else { throw error }
            return cached
        }
    }

    private func requestLatestRelease() async throws -> LatestRelease {
        var request = URLRequest(url: latestReleaseURL)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // Nothing about the machine travels with the request beyond what any download does.
        request.setValue("\(Brand.displayName)/\(InstalledVersion.version()?.description ?? "unbundled")",
                         forHTTPHeaderField: "User-Agent")
        do {
            let (data, response) = try await session.data(for: request)
            guard let http = response as? HTTPURLResponse else {
                throw UpdateCheckError.malformedResponse("the response is not HTTP")
            }
            guard http.statusCode == 200 else {
                throw UpdateCheckError.transport("GitHub answered \(http.statusCode)")
            }
            // Only a well-formed release is remembered, so the fallback can never serve a
            // half-written or foreign payload.
            try LatestReleasePayload.remember(data)
            return try LatestReleasePayload.release(from: data)
        } catch let error as UpdateCheckError {
            throw error
        } catch {
            throw UpdateCheckError.transport(error.localizedDescription)
        }
    }
}

// MARK: - Throttling and dismissal memory

/// When the last check ran, and which version the user silenced. Both are per-user and
/// deliberately small: the timestamp keeps GitHub's rate limit happy, and the silenced tag
/// stops a balloon from reappearing every day until the user upgrades.
public enum UpdateCheckState {
    public static let lastCheckDefaultsKey = "ProxyMaxxLastUpdateCheck"
    public static let dismissedVersionDefaultsKey = "ProxyMaxxDismissedUpdateVersion"
    /// One check a day. The GitHub endpoint treats an unauthenticated client as 60 requests
    /// an hour, so this is far below any limit and the app never appears to poll.
    public static let interval: TimeInterval = 24 * 60 * 60
    /// A manually triggered check from Settings ignores the interval only after this long,
    /// so a double click cannot burn two requests.
    public static let manualInterval: TimeInterval = 60

    /// The forced path for a build with no bundle version to compare, so the UI can be
    /// exercised from `Scripts/run.sh` without shipping the loop to users.
    public static let smokeTestVariable = "PROXYMAXX_UPDATE_SMOKE_TEST"

    public static var isSmokeTest: Bool {
        !(ProcessInfo.processInfo.environment[smokeTestVariable] ?? "").isEmpty
    }

    public static func isCheckDue(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        lastCheck(defaults: defaults).map { now.timeIntervalSince($0) >= interval } ?? true
    }

    public static func isManualCheckAllowed(
        now: Date = Date(),
        defaults: UserDefaults = .standard
    ) -> Bool {
        lastCheck(defaults: defaults).map { now.timeIntervalSince($0) >= manualInterval } ?? true
    }

    public static func lastCheck(defaults: UserDefaults = .standard) -> Date? {
        defaults.object(forKey: lastCheckDefaultsKey) as? Date
    }

    public static func recordCheck(at date: Date = Date(), defaults: UserDefaults = .standard) {
        defaults.set(date, forKey: lastCheckDefaultsKey)
    }

    public static func dismissedVersion(defaults: UserDefaults = .standard) -> ReleaseVersion? {
        (defaults.string(forKey: dismissedVersionDefaultsKey)).flatMap(ReleaseVersion.init)
    }

    public static func dismiss(version: ReleaseVersion, defaults: UserDefaults = .standard) {
        defaults.set(version.description, forKey: dismissedVersionDefaultsKey)
    }

    /// A newer release than the one the user silenced: the balloon is owed again.
    public static func shouldOffer(
        _ release: LatestRelease,
        installed: ReleaseVersion,
        defaults: UserDefaults = .standard
    ) -> Bool {
        guard release.version > installed else { return false }
        return dismissedVersion(defaults: defaults).map { release.version > $0 } ?? true
    }
}

// MARK: - Upgrading through Homebrew

/// What the balloon can do about a newer release. The app is ad-hoc signed and the cask is
/// not notarised, so the app never downloads and swaps its own binary: Homebrew does the
/// swap, and when it cannot, the user gets the command to run or the release page.
public enum UpdateAction: Equatable, Sendable {
    /// `brew upgrade --cask <ref>`: only offered to an install the cask owns.
    case homebrewUpgrade
    /// Copyable command, for a DMG install: the user runs it, or installs the new DMG.
    case copyCommand(String)
}

public enum UpdatePlan {
    /// The shell command the balloon offers to copy.
    public static func homebrewCommand(for origin: InstallOrigin) -> String {
        let reference = InstallOriginDetector.caskReference
        switch origin {
        case .homebrew:
            return "brew upgrade --cask \(reference)"
        case .directDownload, .development:
            return "brew install --cask \(reference)"
        }
    }

    public static func action(for origin: InstallOrigin) -> UpdateAction {
        switch origin {
        case .homebrew: return .homebrewUpgrade
        case .directDownload, .development: return .copyCommand(homebrewCommand(for: origin))
        }
    }
}

/// Runs `brew`, never from the app's own environment: a Finder-launched app inherits none of
/// the shell's `PATH`, and Homebrew's `bin` is not in the system default. `/bin/zsh -lc`
/// sources the login profile, which is where the user's `brew` is set up.
public enum HomebrewUpgrader {
    public static let shell = "/bin/zsh"
    public static let upgradeCommand = "brew upgrade --cask \(InstallOriginDetector.caskReference)"

    public struct Outcome: Equatable, Sendable {
        public let succeeded: Bool
        /// Combined output, for the log and the "it failed" copy.
        public let output: String
        /// True when `brew` itself was not found. The Homebrew install command is the only
        /// thing that can fix that, so the balloon offers it instead of retrying.
        public let brewMissing: Bool

        public init(succeeded: Bool, output: String, brewMissing: Bool) {
            self.succeeded = succeeded
            self.output = output
            self.brewMissing = brewMissing
        }
    }

    /// True when a `brew` answers at all. A copy installed by Homebrew always has one, so
    /// this only guards against a brew that was since removed or is not on the login `PATH`.
    public static func isAvailable() -> Bool {
        guard let result = try? Shell.run(shell, ["-lc", "command -v brew"]) else { return false }
        return result.succeeded && !result.output.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Runs the upgrade with `HOMEBREW_NO_AUTO_UPDATE=1`: the cask's own metadata is
    /// refreshed by the tap, and the unconditional auto-update would turn a one-cask upgrade
    /// into a multi-minute Homebrew update the user did not ask for.
    public static func upgrade() -> Outcome {
        let script = "HOMEBREW_NO_AUTO_UPDATE=1 \(upgradeCommand)"
        guard let result = try? Shell.run(shell, ["-lc", script]) else {
            return Outcome(succeeded: false, output: "The update command could not be started.", brewMissing: true)
        }
        let output = [result.output, result.error]
            .filter { !$0.isEmpty }
            .joined(separator: "\n")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let missing = result.status == 127
            || output.localizedCaseInsensitiveContains("command not found: brew")
        return Outcome(succeeded: result.succeeded && !missing, output: output, brewMissing: missing)
    }
}
