import XCTest
@testable import SystemKit
import Branding

/// Covers the decisions the update balloon cannot get wrong: which release counts as newer,
/// which copy of the app is a real installation, and which upgrade it may offer.
final class UpdateCheckTests: XCTestCase {
    private let payload = """
    {
      "tag_name": "v0.6.0",
      "html_url": "https://github.com/AgiMaulana/ProxyMaxx/releases/tag/v0.6.0",
      "assets": [
        {"name": "notes.txt", "browser_download_url": "https://github.com/x/notes.txt"},
        {"name": "ProxyMaxx-v0.6.0.dmg", "browser_download_url": "https://github.com/x/ProxyMaxx-v0.6.0.dmg"}
      ]
    }
    """

    // MARK: - Versions

    func testVersionParsingAcceptsTagAndPlainForms() {
        XCTAssertEqual(ReleaseVersion("v0.6.0"), ReleaseVersion(major: 0, minor: 6, patch: 0))
        XCTAssertEqual(ReleaseVersion("0.6.0"), ReleaseVersion(major: 0, minor: 6, patch: 0))
        XCTAssertEqual(ReleaseVersion("1.2"), ReleaseVersion(major: 1, minor: 2, patch: 0))
        XCTAssertEqual(ReleaseVersion(" v10.20.30 "), ReleaseVersion(major: 10, minor: 20, patch: 30))
    }

    func testVersionParsingRejectsWhatItCannotCompare() {
        for text in ["", "v", "latest", "0", "1.2.3.4", "1.x.0", "-1.0.0", "1.2.3-beta.1", "1..0"] {
            XCTAssertNil(ReleaseVersion(text), "\(text) must not parse")
        }
    }

    func testVersionsCompareNumericallyNotLexically() {
        XCTAssertLessThan(ReleaseVersion("0.9.0")!, ReleaseVersion("0.10.0")!)
        XCTAssertLessThan(ReleaseVersion("0.10.9")!, ReleaseVersion("0.10.10")!)
        XCTAssertGreaterThan(ReleaseVersion("v1.0.0")!, ReleaseVersion("0.99.99")!)
        XCTAssertEqual(ReleaseVersion("1.0")!, ReleaseVersion("1.0.0")!)
        XCTAssertFalse(ReleaseVersion("0.6.0")! < ReleaseVersion("0.6.0")!)
    }

    func testInstalledVersionIsOnlyComparableInsideABundle() {
        // `swift run` has no Info.plist version to compare, so it never claims to be behind.
        XCTAssertNil(InstalledVersion.comparableVersion(bundle: Bundle(for: type(of: self))))
    }

    // MARK: - Payload

    func testPayloadReadsTagPageAndDmg() throws {
        let release = try LatestReleasePayload.release(from: Data(payload.utf8))
        XCTAssertEqual(release.tagName, "v0.6.0")
        XCTAssertEqual(release.version, ReleaseVersion("0.6.0")!)
        XCTAssertEqual(release.pageURL.absoluteString,
                       "https://github.com/AgiMaulana/ProxyMaxx/releases/tag/v0.6.0")
        XCTAssertEqual(release.dmgURL?.lastPathComponent, "ProxyMaxx-v0.6.0.dmg")
    }

    func testPayloadToleratesAReleaseWithoutADmg() throws {
        let json = #"{"tag_name":"v0.7.0","html_url":"https://github.com/AgiMaulana/ProxyMaxx/releases/tag/v0.7.0"}"#
        let release = try LatestReleasePayload.release(from: Data(json.utf8))
        XCTAssertNil(release.dmgURL)
        XCTAssertEqual(release.version, ReleaseVersion("0.7.0")!)
    }

    func testPayloadRefusesWhatItCannotOpenSafely() {
        let cases = [
            "not json",
            #"{"tag_name":"nightly","html_url":"https://github.com/a/b"}"#,
            #"{"html_url":"https://github.com/a/b"}"#,
            #"{"tag_name":"v1.0.0"}"#,
            // A release page is opened in the browser, so it must not be an arbitrary host.
            #"{"tag_name":"v1.0.0","html_url":"http://github.com/a/b"}"#,
            #"{"tag_name":"v1.0.0","html_url":"https://example.com/a/b"}"#
        ]
        for json in cases {
            XCTAssertThrowsError(try LatestReleasePayload.release(from: Data(json.utf8)), json)
        }
    }

    func testCachedReleaseSurvivesARestartAndIsReRead() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try LatestReleasePayload.remember(Data(payload.utf8), directory: directory)

        let cached = try XCTUnwrap(LatestReleasePayload.cachedRelease(directory: directory))
        XCTAssertEqual(cached.version, ReleaseVersion("0.6.0")!)
        XCTAssertEqual(cached.dmgURL?.lastPathComponent, "ProxyMaxx-v0.6.0.dmg")
    }

    func testCorruptOrForeignCacheIsIgnored() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let file = directory.appendingPathComponent("latest-release.json")
        try Data(#"{"tag_name":"nightly","html_url":"https://github.com/a/b"}"#.utf8).write(to: file)
        XCTAssertNil(LatestReleasePayload.cachedRelease(directory: directory))
        XCTAssertNil(LatestReleasePayload.cachedRelease(directory: directory.appendingPathComponent("absent")))
    }

    // MARK: - Offering

    func testOnlyANewerReleaseIsOffered() {
        let defaults = freshDefaults()
        let installed = ReleaseVersion("0.5.0")!
        XCTAssertTrue(UpdateCheckState.shouldOffer(release("0.6.0"), installed: installed, defaults: defaults))
        XCTAssertFalse(UpdateCheckState.shouldOffer(release("0.5.0"), installed: installed, defaults: defaults))
        XCTAssertFalse(UpdateCheckState.shouldOffer(release("0.4.9"), installed: installed, defaults: defaults))
    }

    func testDismissingSilencesOnlyThatVersion() {
        let defaults = freshDefaults()
        let installed = ReleaseVersion("0.5.0")!
        UpdateCheckState.dismiss(version: ReleaseVersion("0.6.0")!, defaults: defaults)
        XCTAssertFalse(UpdateCheckState.shouldOffer(release("0.6.0"), installed: installed, defaults: defaults))
        XCTAssertTrue(UpdateCheckState.shouldOffer(release("0.7.0"), installed: installed, defaults: defaults))
    }

    func testDismissingAnOlderVersionDoesNotSilenceANewerOne() {
        let defaults = freshDefaults()
        UpdateCheckState.dismiss(version: ReleaseVersion("0.6.0")!, defaults: defaults)
        XCTAssertTrue(UpdateCheckState.shouldOffer(
            release("0.6.1"),
            installed: ReleaseVersion("0.5.0")!,
            defaults: defaults
        ))
    }

    // MARK: - Throttling

    func testFirstLaunchIsDue() {
        XCTAssertTrue(UpdateCheckState.isCheckDue(defaults: freshDefaults()))
    }

    func testOneCheckPerDay() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_000_000)
        UpdateCheckState.recordCheck(at: now, defaults: defaults)
        XCTAssertFalse(UpdateCheckState.isCheckDue(now: now.addingTimeInterval(23 * 3600), defaults: defaults))
        XCTAssertTrue(UpdateCheckState.isCheckDue(now: now.addingTimeInterval(24 * 3600), defaults: defaults))
    }

    func testManualCheckIsRateLimitedSeparately() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_000_000)
        UpdateCheckState.recordCheck(at: now, defaults: defaults)
        // The daily window is still shut, but Settings may ask again almost immediately.
        XCTAssertFalse(UpdateCheckState.isCheckDue(now: now.addingTimeInterval(120), defaults: defaults))
        XCTAssertFalse(UpdateCheckState.isManualCheckAllowed(now: now.addingTimeInterval(30), defaults: defaults))
        XCTAssertTrue(UpdateCheckState.isManualCheckAllowed(now: now.addingTimeInterval(61), defaults: defaults))
    }

    func testManualCheckIsAllowedWhenNothingRanYet() {
        XCTAssertTrue(UpdateCheckState.isManualCheckAllowed(defaults: freshDefaults()))
    }

    // MARK: - Install origin

    func testCheckoutAndBuildCopiesAreDevelopment() {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        for path in ["\(root.path)/dist/ProxyMaxx.app", "\(root.path)/.build/release/ProxyMaxx.app"] {
            XCTAssertEqual(InstallOriginDetector.origin(bundleURL: URL(fileURLWithPath: path)), .development, path)
        }
    }

    func testApplicationsCopyWithoutACaskEntryIsADirectDownload() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        // A DMG drag lands in /Applications and leaves no Caskroom entry behind.
        let bundle = fixture.applications.appendingPathComponent(InstallOriginDetector.appBundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: fixture.caskroom, withIntermediateDirectories: true)

        let origin = InstallOriginDetector.origin(
            bundleURL: bundle,
            applicationsDirectory: fixture.applications.path,
            caskroomDirectories: [fixture.caskroom]
        )
        XCTAssertEqual(origin, .directDownload)
    }

    func testApplicationsCopyLinkedFromTheCaskroomIsHomebrew() throws {
        let fixture = try Fixture()
        defer { fixture.remove() }
        let bundle = fixture.applications.appendingPathComponent(InstallOriginDetector.appBundleName)
        try FileManager.default.createDirectory(at: bundle, withIntermediateDirectories: true)
        let installed = fixture.caskroom
            .appendingPathComponent(InstallOriginDetector.caskToken, isDirectory: true)
            .appendingPathComponent("0.5.0", isDirectory: true)
        try FileManager.default.createDirectory(at: installed, withIntermediateDirectories: true)
        try FileManager.default.createSymbolicLink(
            at: installed.appendingPathComponent(InstallOriginDetector.appBundleName),
            withDestinationURL: bundle
        )

        let origin = InstallOriginDetector.origin(
            bundleURL: bundle,
            applicationsDirectory: fixture.applications.path,
            caskroomDirectories: [fixture.caskroom]
        )
        XCTAssertEqual(origin, .homebrew)
    }

    // MARK: - Upgrade

    func testHomebrewInstallOffersTheBrewUpgrade() {
        XCTAssertEqual(UpdatePlan.action(for: .homebrew), .homebrewUpgrade)
        XCTAssertEqual(
            UpdatePlan.homebrewCommand(for: .homebrew),
            "brew upgrade --cask AgiMaulana/proxymaxx/proxymaxx"
        )
    }

    func testDirectDownloadGetsACopyableCommand() {
        XCTAssertEqual(
            UpdatePlan.action(for: .directDownload),
            .copyCommand("brew install --cask AgiMaulana/proxymaxx/proxymaxx")
        )
    }

    func testUpgradeCommandNamesTheFullyQualifiedCask() {
        XCTAssertTrue(HomebrewUpgrader.upgradeCommand.contains("AgiMaulana/proxymaxx/proxymaxx"))
        XCTAssertTrue(HomebrewUpgrader.upgradeCommand.hasPrefix("brew upgrade --cask "))
    }

    func testAKnownBrewBinaryIsUsedBeforeTheLoginShellProbe() {
        // `/bin/ls` stands in for an existing executable, so the resolver answers it and
        // never reaches the login-shell probe.
        XCTAssertEqual(HomebrewUpgrader.brewPath(candidates: ["/bin/ls", "/no/such/brew"]), "/bin/ls")
    }

    func testAnUnknownBrewFallsThroughToTheLoginShellProbe() {
        let resolved = HomebrewUpgrader.brewPath(candidates: ["/no/such/brew"])
        // A result must be a real executable; nil is equally valid, because the machine
        // running the tests may have no brew anywhere.
        if let resolved {
            XCTAssertTrue(FileManager.default.isExecutableFile(atPath: resolved), resolved)
        }
    }

    // MARK: - Revalidation

    func testUpdateRequestsBypassTheSystemProxy() {
        let proxies = GitHubUpdateChecker.makeConfiguration().connectionProxyDictionary
        // An empty dictionary disables proxying; nil would mean "use the system's".
        XCTAssertEqual(proxies.map(\.count), 0)
    }

    func testETagRoundTripsAndClears() {
        let defaults = freshDefaults()
        XCTAssertNil(UpdateCheckState.latestETag(defaults: defaults))
        UpdateCheckState.recordETag(#"W/"0123abcd""#, defaults: defaults)
        XCTAssertEqual(UpdateCheckState.latestETag(defaults: defaults), #"W/"0123abcd""#)
        UpdateCheckState.recordETag(nil, defaults: defaults)
        XCTAssertNil(UpdateCheckState.latestETag(defaults: defaults))
        UpdateCheckState.recordETag("", defaults: defaults)
        XCTAssertNil(UpdateCheckState.latestETag(defaults: defaults))
    }

    func testAKnownETagMakesTheNextLaunchCheckImmediately() {
        let defaults = freshDefaults()
        let now = Date(timeIntervalSince1970: 1_000_000)
        UpdateCheckState.recordCheck(at: now, defaults: defaults)
        XCTAssertFalse(UpdateCheckState.isCheckDue(now: now.addingTimeInterval(3_600), defaults: defaults))
        // A conditional revalidation is free against the rate limit, so it does not wait
        // out the daily window — a release published minutes after the last check is
        // caught on the next launch.
        UpdateCheckState.recordETag(#"W/"0123abcd""#, defaults: defaults)
        XCTAssertTrue(UpdateCheckState.isCheckDue(now: now.addingTimeInterval(3_600), defaults: defaults))
    }

    func testAFullCheckStoresThePayloadAndItsETag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = freshDefaults()
        let checker = stubbedChecker(directory: directory, defaults: defaults) { _ in
            (200, ["ETag": #""v0.7.0-etag""#], Self.payload(tag: "v0.7.0"))
        }
        let release = try await checker.fetchLatestRelease()
        XCTAssertEqual(release.version, ReleaseVersion("0.7.0")!)
        XCTAssertEqual(UpdateCheckState.latestETag(defaults: defaults), #""v0.7.0-etag""#)
        XCTAssertNotNil(LatestReleasePayload.cachedRelease(directory: directory))
    }

    func testANotModifiedAnswerServesTheCachedReleaseAndSentTheETag() async throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: directory) }
        let defaults = freshDefaults()
        try LatestReleasePayload.remember(Self.payload(tag: "v0.6.0"), directory: directory)
        UpdateCheckState.recordETag(#""v0.6.0-etag""#, defaults: defaults)

        var sentETag: String?
        let checker = stubbedChecker(directory: directory, defaults: defaults) { request in
            sentETag = request.value(forHTTPHeaderField: "If-None-Match")
            return (304, [:], Data())
        }
        let release = try await checker.fetchLatestRelease()
        XCTAssertEqual(sentETag, #""v0.6.0-etag""#)
        XCTAssertEqual(release.version, ReleaseVersion("0.6.0")!)
    }

    /// Answers every request the check makes from a handler, so the conditional-request
    /// behavior is tested without GitHub on the wire.
    private final class UpdateCheckStubProtocol: URLProtocol {
        static var handler: ((URLRequest) -> (Int, [String: String], Data))?

        override class func canInit(with request: URLRequest) -> Bool { true }
        override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

        override func startLoading() {
            guard let handler = Self.handler, let url = request.url else {
                client?.urlProtocol(self, didFailWithError: URLError(.badURL))
                return
            }
            let (status, headers, body) = handler(request)
            let response = HTTPURLResponse(
                url: url, statusCode: status, httpVersion: "HTTP/1.1", headerFields: headers
            )!
            client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
            if !body.isEmpty {
                client?.urlProtocol(self, didLoad: body)
            }
            client?.urlProtocolDidFinishLoading(self)
        }

        override func stopLoading() {}
    }

    private func stubbedChecker(
        directory: URL,
        defaults: UserDefaults,
        handler: @escaping (URLRequest) -> (Int, [String: String], Data)
    ) -> GitHubUpdateChecker {
        UpdateCheckStubProtocol.handler = handler
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [UpdateCheckStubProtocol.self]
        return GitHubUpdateChecker(
            session: URLSession(configuration: configuration),
            cacheDirectory: directory,
            defaults: defaults
        )
    }

    /// A throwaway `/Applications` + Caskroom pair, so the origin tests never read the real
    /// Homebrew opt directory of the machine running them.
    private struct Fixture {
        let root: URL
        let applications: URL
        let caskroom: URL

        init() throws {
            root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
            applications = root.appendingPathComponent("Applications", isDirectory: true)
            caskroom = root.appendingPathComponent("Caskroom", isDirectory: true)
            try FileManager.default.createDirectory(
                at: applications,
                withIntermediateDirectories: true
            )
        }

        func remove() { try? FileManager.default.removeItem(at: root) }
    }

    // MARK: - Helpers

    /// A minimal `/releases/latest` payload naming `tag`.
    private static func payload(tag: String) -> Data {
        let json = #"{"tag_name":"\#(tag)","html_url":"https://github.com/AgiMaulana/ProxyMaxx/releases/tag/\#(tag)"}"#
        return Data(json.utf8)
    }

    private func freshDefaults() -> UserDefaults {
        let suite = "UpdateCheckTests-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suite)!
        defaults.removePersistentDomain(forName: suite)
        addTeardownBlock { defaults.removePersistentDomain(forName: suite) }
        return defaults
    }

    private func release(_ version: String) -> LatestRelease {
        LatestRelease(
            tagName: "v\(version)",
            version: ReleaseVersion(version)!,
            pageURL: URL(string: "https://github.com/AgiMaulana/ProxyMaxx/releases/tag/v\(version)")!,
            dmgURL: nil
        )
    }
}
