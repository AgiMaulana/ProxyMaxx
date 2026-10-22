import XCTest
@testable import RuleKit
import FlowKit

final class MapLocalMatcherTests: XCTestCase {
    private func request(
        method: String = "GET",
        scheme: String = "https",
        host: String = "api.example.com",
        port: Int = 443,
        path: String = "/v1/users"
    ) -> HTTPRequest {
        HTTPRequest(method: method, scheme: scheme, host: host, port: port, path: path)
    }

    func testContainsMatchesHostAndPath() {
        let rule = MapLocalRule(url: "api.example.com/v1", matchStyle: .contains)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request()))
    }

    func testContainsIgnoresPathWhenNotIncluded() {
        let rule = MapLocalRule(url: "api.example.com", matchStyle: .contains, includePath: false)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(path: "/anything/else")))

        let withPath = MapLocalRule(url: "api.example.com/v1", matchStyle: .contains, includePath: false)
        XCTAssertFalse(
            MapLocalMatcher.matches(withPath, request: request()),
            "the path is not part of the comparison when includePath is off"
        )
    }

    func testWildcardMatchesWholeURL() {
        let rule = MapLocalRule(url: "api.example.com/v1/*", matchStyle: .wildcard)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(path: "/v1/users/7")))
        XCTAssertFalse(MapLocalMatcher.matches(rule, request: request(path: "/v2/users")))
    }

    func testRegexIsAFullMatch() {
        let rule = MapLocalRule(url: "api.example.com/v1/(.*)", matchStyle: .regex)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(path: "/v1/users")))

        // The pattern matches a prefix of the URL but not all of it, so a full-match
        // regex must reject it. ProxyMaxx calls this style "full-matching regex".
        let prefixOnly = MapLocalRule(url: "api.example.com/v1", matchStyle: .regex)
        XCTAssertFalse(MapLocalMatcher.matches(prefixOnly, request: request()))
    }

    func testRegexKeepsTheCaseOfEscapeClasses() {
        // `\S+` (non-space) must not be folded to `\s+` (space), which would match nothing
        // in a URL. The pattern is a full match, so the escape covers the whole tail.
        let rule = MapLocalRule(url: "api.example.com/v1/\\S+", matchStyle: .regex)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(path: "/v1/users")))

        let upperClass = MapLocalRule(url: "api.example.com/v1/[A-Z]+", matchStyle: .regex)
        XCTAssertTrue(MapLocalMatcher.matches(upperClass, request: request(path: "/v1/users")))
    }

    func testExactRequiresTheWholeURL() {
        let rule = MapLocalRule(url: "api.example.com/v1/users", matchStyle: .exact)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request()))
        XCTAssertFalse(MapLocalMatcher.matches(rule, request: request(path: "/v1/users/7")))
    }

    func testSchemeInThePatternIsStripped() {
        let rule = MapLocalRule(url: "https://api.example.com/v1/*", matchStyle: .wildcard)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(path: "/v1/users")))
    }

    func testNonDefaultPortIsPartOfTheTarget() {
        let rule = MapLocalRule(url: "api.example.com:8443/*", matchStyle: .wildcard)
        XCTAssertTrue(MapLocalMatcher.matches(rule, request: request(port: 8443, path: "/v1/users")))
        XCTAssertFalse(MapLocalMatcher.matches(rule, request: request()))
    }

    func testMethodFilter() {
        let anyMethod = MapLocalRule(url: "api.example.com", matchStyle: .contains, includePath: false)
        XCTAssertTrue(MapLocalMatcher.matches(anyMethod, request: request(method: "DELETE")))

        let postOnly = MapLocalRule(method: MethodMatch("POST"), url: "api.example.com", matchStyle: .contains, includePath: false)
        XCTAssertTrue(MapLocalMatcher.matches(postOnly, request: request(method: "post")))
        XCTAssertFalse(MapLocalMatcher.matches(postOnly, request: request(method: "GET")))
    }

    func testDisabledAndEmptyRulesNeverMatch() {
        let disabled = MapLocalRule(isEnabled: false, url: "*", matchStyle: .wildcard)
        XCTAssertFalse(MapLocalMatcher.matches(disabled, request: request()))

        let empty = MapLocalRule(url: "  ", matchStyle: .contains)
        XCTAssertFalse(MapLocalMatcher.matches(empty, request: request()), "an empty pattern must not act as a catch-all")
    }

    func testFirstMatchWins() {
        let first = MapLocalRule(name: "first", url: "api.example.com/v1/*", matchStyle: .wildcard)
        let second = MapLocalRule(name: "second", url: "api.example.com/*", matchStyle: .wildcard)
        let winner = MapLocalMatcher.firstMatch(in: [first, second], request: request())
        XCTAssertEqual(winner?.name, "first")
    }

    func testDisabledRuleIsSkippedInFavourOfTheNextMatch() {
        let disabled = MapLocalRule(name: "disabled", isEnabled: false, url: "api.example.com/*", matchStyle: .wildcard)
        let enabled = MapLocalRule(name: "enabled", url: "api.example.com/v1/*", matchStyle: .wildcard)
        let winner = MapLocalMatcher.firstMatch(in: [disabled, enabled], request: request())
        XCTAssertEqual(winner?.name, "enabled")
    }

    func testInvalidRegexDoesNotMatch() {
        let rule = MapLocalRule(url: "api.example.com/([", matchStyle: .regex)
        XCTAssertFalse(MapLocalMatcher.matches(rule, request: request()))
    }
}

final class MapLocalResponderTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory.appendingPathComponent("maplocal-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    private func write(_ text: String, to name: String) throws -> URL {
        let url = directory.appendingPathComponent(name)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        return url
    }

    private func request(path: String = "/v1/users") -> HTTPRequest {
        HTTPRequest(method: "GET", scheme: "https", host: "api.example.com", port: 443, path: path)
    }

    func testBodyFileIsServedWithAnInferredContentType() throws {
        let file = try write("{\"a\":1}", to: "body.json")
        let rule = MapLocalRule(url: "api.example.com/*", matchStyle: .wildcard, destination: .file(file.path))

        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(), rules: [rule]) else {
            return XCTFail("expected the rule to serve")
        }
        XCTAssertEqual(resolution.response.statusCode, 200)
        XCTAssertEqual(resolution.response.body, Data("{\"a\":1}".utf8))
        XCTAssertEqual(resolution.response.headers["Content-Type"], "application/json")
        XCTAssertEqual(resolution.response.headers["Content-Length"], "7")
    }

    func testFullHTTPMessageFileIsServedWhole() throws {
        let message = """
        HTTP/1.1 404 Not Found\r
        Content-Type: text/plain\r
        X-Mapped: yes\r
        Content-Length: 999\r
        \r
        nope
        """
        let file = try write(message, to: "message.txt")
        let rule = MapLocalRule(url: "api.example.com/*", matchStyle: .wildcard, destination: .file(file.path))

        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(), rules: [rule]) else {
            return XCTFail("expected the rule to serve")
        }
        XCTAssertEqual(resolution.response.statusCode, 404)
        XCTAssertEqual(resolution.response.headers["X-Mapped"], "yes")
        XCTAssertEqual(resolution.response.body, Data("nope".utf8))
        XCTAssertEqual(
            resolution.response.headers["Content-Length"], "4",
            "the framing must come from the body the file actually carries"
        )
    }

    func testFileReferenceIndirection() throws {
        let target = try write("indirect", to: "target.txt")
        let pointer = try write("<FILE_URL=\"\(target.path)\">", to: "pointer.txt")
        let rule = MapLocalRule(url: "api.example.com/*", matchStyle: .wildcard, destination: .file(pointer.path))

        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(), rules: [rule]) else {
            return XCTFail("expected the rule to serve")
        }
        XCTAssertEqual(resolution.response.body, Data("indirect".utf8))
        XCTAssertEqual(resolution.servedPath, target.path)
    }

    func testMissingFileFallsThrough() {
        let rule = MapLocalRule(
            name: "gone",
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .file(directory.appendingPathComponent("missing.json").path)
        )
        guard case .unusable(let ruleName, let reason)? = MapLocalResponder.resolve(request: request(), rules: [rule]) else {
            return XCTFail("a missing file must not be served")
        }
        XCTAssertEqual(ruleName, "gone")
        XCTAssertTrue(reason.contains("missing"), reason)
    }

    func testNoMatchingRuleIsNil() {
        let rule = MapLocalRule(url: "other.example.com/*", matchStyle: .wildcard, destination: .file("/tmp/x"))
        XCTAssertNil(MapLocalResponder.resolve(request: request(), rules: [rule]))
    }

    func testDirectoryServesTheRequestPath() throws {
        _ = try write("list", to: "v1/users.json")
        let rule = MapLocalRule(
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .directory(directory.path)
        )
        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(path: "/v1/users.json"), rules: [rule]) else {
            return XCTFail("expected the directory to serve")
        }
        XCTAssertEqual(resolution.response.body, Data("list".utf8))
        XCTAssertEqual(resolution.response.headers["Content-Type"], "application/json")
    }

    func testDirectoryFallsBackToIndexHTML() throws {
        _ = try write("<h1>home</h1>", to: "v1/index.html")
        let rule = MapLocalRule(
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .directory(directory.path)
        )
        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(path: "/v1/"), rules: [rule]) else {
            return XCTFail("expected index.html to serve")
        }
        XCTAssertEqual(resolution.response.body, Data("<h1>home</h1>".utf8))
        XCTAssertEqual(resolution.response.headers["Content-Type"], "text/html")
    }

    func testMissingDirectoryEntryFallsThrough() throws {
        let rule = MapLocalRule(
            name: "mock",
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .directory(directory.path)
        )
        guard case .unusable? = MapLocalResponder.resolve(request: request(path: "/nothing/here"), rules: [rule]) else {
            return XCTFail("a path with no file must fall through")
        }
    }

    func testDelayIsCarriedFromTheRule() throws {
        let file = try write("late", to: "late.txt")
        let rule = MapLocalRule(
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .file(file.path),
            responseDelay: 2
        )
        guard case .served(let resolution)? = MapLocalResponder.resolve(request: request(), rules: [rule]) else {
            return XCTFail("expected the rule to serve")
        }
        XCTAssertEqual(resolution.delay, 2)
    }

    func testDirectoryTargetRefusesTraversal() {
        XCTAssertNil(MapLocalResponder.directoryTarget(root: directory, requestPath: "/../../etc/passwd"))
        XCTAssertNil(MapLocalResponder.directoryTarget(root: directory, requestPath: "/v1/../../../etc/passwd"))
    }

    func testDirectoryTargetIgnoresDotSegmentsAndDecodesPercentEscapes() throws {
        _ = try write("spaced", to: "a b.txt")
        let target = MapLocalResponder.directoryTarget(root: directory, requestPath: "/./a%20b.txt")
        XCTAssertEqual(target?.lastPathComponent, "a b.txt")
    }
}

final class MapLocalRuleStoreTests: XCTestCase {
    @MainActor
    func testDisablingTheToolEmptiesTheEffectiveRules() {
        let store = RuleStore()
        store.addMapLocalRule(MapLocalRule(url: "api.example.com/*"))
        XCTAssertEqual(store.effectiveMapLocalRules.count, 1)

        store.isMapLocalEnabled = false
        XCTAssertTrue(store.effectiveMapLocalRules.isEmpty)
    }

    @MainActor
    func testDuplicateInsertsBesideTheOriginal() {
        let store = RuleStore()
        let rule = MapLocalRule(name: "one", url: "a.example.com/*")
        store.addMapLocalRule(rule)
        store.addMapLocalRule(MapLocalRule(name: "two", url: "b.example.com/*"))

        store.duplicateMapLocalRule(id: rule.id)
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["one", "one copy", "two"])
    }

    @MainActor
    func testReorderMovesTheSelectedRuleToTheTop() {
        let store = RuleStore()
        let first = MapLocalRule(name: "first", url: "a/*")
        let second = MapLocalRule(name: "second", url: "b/*")
        store.addMapLocalRule(first)
        store.addMapLocalRule(second)

        store.moveMapLocalRules(from: IndexSet(integer: 1), to: 0)
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["second", "first"])
    }

    @MainActor
    func testToggleAndRemove() {
        let store = RuleStore()
        let rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)

        store.setMapLocalRule(id: rule.id, enabled: false)
        XCTAssertEqual(store.mapLocalRules.first?.isEnabled, false)

        store.removeMapLocalRules(ids: [rule.id])
        XCTAssertTrue(store.mapLocalRules.isEmpty)
    }

    @MainActor
    func testUpdateReplacesTheRuleInPlace() {
        let store = RuleStore()
        var rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)
        store.addMapLocalRule(MapLocalRule(name: "two", url: "b/*"))

        rule.name = "renamed"
        rule.url = "c/*"
        store.updateMapLocalRule(rule)

        XCTAssertEqual(store.mapLocalRules.map(\.name), ["renamed", "two"])
        XCTAssertEqual(store.mapLocalRules.first?.url, "c/*")
    }

    @MainActor
    func testUpdateOfAnUnknownRuleIsIgnored() {
        let store = RuleStore()
        store.addMapLocalRule(MapLocalRule(name: "one", url: "a/*"))
        store.updateMapLocalRule(MapLocalRule(name: "ghost", url: "z/*"))
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["one"])
    }

    @MainActor
    func testMoveByIdentifierSwapsWithTheNeighbour() {
        let store = RuleStore()
        let first = MapLocalRule(name: "first", url: "a/*")
        let second = MapLocalRule(name: "second", url: "b/*")
        let third = MapLocalRule(name: "third", url: "c/*")
        store.addMapLocalRule(first)
        store.addMapLocalRule(second)
        store.addMapLocalRule(third)

        store.moveMapLocalRule(id: third.id, by: -1)
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["first", "third", "second"])

        store.moveMapLocalRule(id: third.id, by: 1)
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["first", "second", "third"])
    }

    @MainActor
    func testMoveByIdentifierBeyondTheEndIsIgnored() {
        let store = RuleStore()
        let first = MapLocalRule(name: "first", url: "a/*")
        store.addMapLocalRule(first)
        store.moveMapLocalRule(id: first.id, by: -1)
        XCTAssertEqual(store.mapLocalRules.map(\.name), ["first"])
    }
}

final class RuleStorePersistenceTests: XCTestCase {
    /// A file the test owns; `nil` stores are in-memory so the test never touches real
    /// `Application Support` state.
    private func temporaryRulesFile() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleKitTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")
    }

    @MainActor
    func testMapLocalRulesSurviveASecondStore() {
        let url = temporaryRulesFile()
        let store = RuleStore(persistenceURL: url)
        store.addMapLocalRule(MapLocalRule(name: "kept", url: "api.example.com/*", responseDelay: 2))
        store.setMapLocalRule(id: store.mapLocalRules[0].id, enabled: false)
        store.flushRulesToDisk()

        let reloaded = RuleStore(persistenceURL: url)
        XCTAssertEqual(reloaded.mapLocalRules.map(\.name), ["kept"])
        XCTAssertEqual(reloaded.mapLocalRules.first?.url, "api.example.com/*")
        XCTAssertEqual(reloaded.mapLocalRules.first?.isEnabled, false)
        XCTAssertEqual(reloaded.mapLocalRules.first?.responseDelay, 2)
    }

    @MainActor
    func testToolEnableFlagsAndOrderSurviveASecondStore() {
        let url = temporaryRulesFile()
        let store = RuleStore(persistenceURL: url)
        store.isMapLocalEnabled = false
        store.addMapLocalRule(MapLocalRule(name: "first", url: "a/*"))
        store.addMapLocalRule(MapLocalRule(name: "second", url: "b/*"))
        store.moveMapLocalRule(id: store.mapLocalRules[1].id, by: -1)
        store.sslProxyingPolicy = SSLProxyingPolicy(include: ["api.example.com"], exclude: ["*.google.com"])
        store.flushRulesToDisk()

        let reloaded = RuleStore(persistenceURL: url)
        XCTAssertFalse(reloaded.isMapLocalEnabled)
        XCTAssertEqual(reloaded.mapLocalRules.map(\.name), ["second", "first"])
        XCTAssertEqual(reloaded.sslProxyingPolicy, SSLProxyingPolicy(include: ["api.example.com"], exclude: ["*.google.com"]))
    }

    @MainActor
    func testMissingFileLeavesEmptyStoreFromDefaultRules() throws {
        let reloaded = RuleStore(persistenceURL: temporaryRulesFile())
        XCTAssertTrue(reloaded.mapLocalRules.isEmpty)
        XCTAssertTrue(reloaded.isMapLocalEnabled)
    }

    @MainActor
    func testCorruptFileFallsBackToDefaults() throws {
        let url = temporaryRulesFile()
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("not JSON at all".utf8).write(to: url)
        let reloaded = RuleStore(persistenceURL: url)
        XCTAssertTrue(reloaded.mapLocalRules.isEmpty)
        XCTAssertTrue(reloaded.isMapLocalEnabled)
    }

    @MainActor
    func testEmptyStoreWritesBackNothingToLoad() {
        let url = temporaryRulesFile()
        RuleStore(persistenceURL: url).flushRulesToDisk()
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: url.path),
            "an empty store still persists its state so a restart does not re-run defaults"
        )
        let reloaded = RuleStore(persistenceURL: url)
        XCTAssertTrue(reloaded.mapLocalRules.isEmpty)
    }
}

final class MapLocalModelTests: XCTestCase {
    func testURLMatchStylePresentation() {
        XCTAssertEqual(URLMatchStyle.contains.displayName, "Contains")
        XCTAssertEqual(URLMatchStyle.wildcard.displayName, "Match Wildcard")
        XCTAssertEqual(URLMatchStyle.regex.displayName, "Match Regex")
        XCTAssertEqual(URLMatchStyle.exact.displayName, "Exact")
        XCTAssertFalse(URLMatchStyle.regex.help.isEmpty)
    }

    func testMethodMatchPresentationAndAny() {
        XCTAssertTrue(MethodMatch.any.isAny)
        XCTAssertEqual(MethodMatch.any.displayName, "ANY")
        XCTAssertTrue(MethodMatch.any.matches("PATCH"))

        let post = MethodMatch("post")
        XCTAssertFalse(post.isAny)
        XCTAssertEqual(post.displayName, "POST", "the stored method is upper-cased")
        XCTAssertTrue(post.matches("PoSt"))
        XCTAssertFalse(post.matches("GET"))
    }

    func testDestinationPresentation() {
        let file = MapLocalDestination.file("/tmp/a.json")
        XCTAssertEqual(file.path, "/tmp/a.json")
        XCTAssertTrue(file.isFile)
        XCTAssertEqual(file.displayName, "Local File")
        XCTAssertEqual(file.symbolName, "doc")

        let directory = MapLocalDestination.directory("/tmp/mock")
        XCTAssertEqual(directory.path, "/tmp/mock")
        XCTAssertFalse(directory.isFile)
        XCTAssertEqual(directory.displayName, "Local Directory")
        XCTAssertEqual(directory.symbolName, "folder")
    }

    func testRuleDisplayNameFallsBackToThePattern() {
        XCTAssertEqual(MapLocalRule(url: "api.example.com/*").displayName, "api.example.com/*")

        let named = MapLocalRule(name: "  Checkout  ", url: "api.example.com/*")
        XCTAssertEqual(named.displayName, "Checkout", "the name is trimmed and preferred when present")
    }

    func testDelayPresentation() {
        XCTAssertEqual(MapLocalDelay.none.displayName, "No Delay")
        XCTAssertEqual(MapLocalDelay.oneSecond.displayName, "1 second")
        XCTAssertEqual(MapLocalDelay.tenSeconds.displayName, "10 seconds")
        XCTAssertEqual(MapLocalDelay.thirtySeconds.displayName, "30 seconds")
    }

    func testDelayClosestPreset() {
        XCTAssertEqual(MapLocalDelay.closest(to: 0), MapLocalDelay.none)
        XCTAssertEqual(MapLocalDelay.closest(to: 2.1), .twoSeconds)
        XCTAssertNil(MapLocalDelay.closest(to: 7), "a value more than 0.5s from every preset has no closest preset")
    }

    func testResolutionSourceDescription() {
        let resolution = MapLocalResolution(
            ruleName: "rule",
            destination: .file("/tmp/mock.json"),
            servedPath: "/tmp/mock.json",
            response: HTTPResponse(statusCode: 200),
            delay: 0
        )
        XCTAssertEqual(resolution.sourceDescription, "Local File: /tmp/mock.json")
    }
}

final class MapLocalResponderEdgeCaseTests: XCTestCase {
    func testBodyIsStrippedForStatusesThatForbidOne() {
        for code in [204, 304, 101] {
            var message = HTTPResponse(statusCode: code)
            message.headers["Content-Length"] = "512"
            message.headers["Transfer-Encoding"] = "chunked"
            message.body = Data("should not survive".utf8)

            let normalized = MapLocalResponder.normalized(message, pathExtension: "txt")
            XCTAssertTrue(normalized.body.isEmpty, "status \(code) must not carry a body")
            XCTAssertNil(normalized.headers["Content-Length"], "status \(code) must drop Content-Length")
            XCTAssertNil(normalized.headers["Transfer-Encoding"])
        }
    }

    func testNormalizedInferContentTypeWhenTheMessageOmitsIt() {
        let message = HTTPResponse(statusCode: 200)
        let normalized = MapLocalResponder.normalized(message, pathExtension: "json")
        XCTAssertEqual(normalized.headers["Content-Type"], "application/json")
        XCTAssertEqual(normalized.headers["Content-Length"], "0")
    }

    func testNormalizedKeepsAnExplicitContentType() {
        var message = HTTPResponse(statusCode: 200)
        message.headers["Content-Type"] = "text/csv"
        let normalized = MapLocalResponder.normalized(message, pathExtension: "json")
        XCTAssertEqual(normalized.headers["Content-Type"], "text/csv")
    }

    func testLooksLikeHTTPMessageIgnoresLeaderWhitespace() {
        XCTAssertTrue(MapLocalResponder.looksLikeHTTPMessage(Data("\r\n\t  HTTP/1.1 200 OK".utf8)))
        XCTAssertTrue(MapLocalResponder.looksLikeHTTPMessage(Data("HTTP/1.1 200 OK".utf8)))
        XCTAssertFalse(MapLocalResponder.looksLikeHTTPMessage(Data("{\"a\":1}".utf8)))
        XCTAssertFalse(MapLocalResponder.looksLikeHTTPMessage(Data()))
    }

    func testFileReferenceIsDetectedWithStraightAndCurlyQuotes() {
        XCTAssertEqual(MapLocalResponder.fileReference(in: Data("<FILE_URL=\"/tmp/a.json\">".utf8)), "/tmp/a.json")
        XCTAssertEqual(MapLocalResponder.fileReference(in: Data("<FILE_URL=\u{201C}/tmp/b.json\u{201D}>".utf8)), "/tmp/b.json")
    }

    func testFileReferenceIsNilForOrdinaryBodiesAndEmptyReferences() {
        XCTAssertNil(MapLocalResponder.fileReference(in: Data("{\"a\":1}".utf8)))
        XCTAssertNil(MapLocalResponder.fileReference(in: Data("<FILE_URL=\"\">".utf8)))
        XCTAssertNil(MapLocalResponder.fileReference(in: Data("<FILE_URL=\"/tmp/a.json\"".utf8)), "an unterminated reference is not one")
    }

    func testFileReferenceOfADanglingPointerIsUnusable() throws {
        let directory = FileManager.default.temporaryDirectory.appendingPathComponent("maplocal-edge-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let pointer = directory.appendingPathComponent("pointer.txt")
        try Data("<FILE_URL=\"/definitely/not/here.json\">".utf8).write(to: pointer)

        let rule = MapLocalRule(
            name: "dangling",
            url: "api.example.com/*",
            matchStyle: .wildcard,
            destination: .file(pointer.path)
        )
        let request = HTTPRequest(method: "GET", scheme: "https", host: "api.example.com", port: 443, path: "/v1/users")
        guard case .unusable? = MapLocalResponder.resolve(request: request, rules: [rule]) else {
            return XCTFail("a pointer to a missing file must fall through")
        }
    }

    func testDirectoryTargetRejectsASymlinkEscape() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("maplocal-sym-\(UUID().uuidString)")
        let outside = FileManager.default.temporaryDirectory.appendingPathComponent("maplocal-out-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: true)
        defer {
            try? FileManager.default.removeItem(at: root)
            try? FileManager.default.removeItem(at: outside)
        }

        let secret = outside.appendingPathComponent("secret.txt")
        try Data("secret".utf8).write(to: secret)
        let link = root.appendingPathComponent("link.txt")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: secret)

        XCTAssertNil(
            MapLocalResponder.directoryTarget(root: root, requestPath: "/link.txt"),
            "a symlink that leaves the root is not served"
        )
    }
}
