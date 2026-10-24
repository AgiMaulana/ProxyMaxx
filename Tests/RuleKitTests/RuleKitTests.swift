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

final class MapLocalScenarioTests: XCTestCase {
    private func rules(_ names: [String]) -> [MapLocalRule] {
        names.map { MapLocalRule(name: $0, url: "\($0).example.com/*") }
    }

    func testActivateTurnsOnOnlyTheScenariosRules() {
        var list = rules(["consultation", "prescription", "follow-up"])
        list[1].isEnabled = true
        let scenario = MapLocalScenario(name: "visit", ruleIDs: [list[0].id, list[2].id])

        let applied = MapLocalScenarioRunner.activate(scenario, in: &list)

        XCTAssertEqual(applied, 2)
        XCTAssertEqual(list.map(\.isEnabled), [true, false, true],
                       "a rule outside the scenario must be off, even if it was on before")
    }

    func testActivateIgnoresRulesDeletedSinceCapture() {
        var list = rules(["consultation"])
        var scenario = MapLocalScenario(name: "visit", ruleIDs: [list[0].id, UUID()])
        scenario.ruleIDs.append(UUID())

        let applied = MapLocalScenarioRunner.activate(scenario, in: &list)

        XCTAssertEqual(applied, 1)
        XCTAssertTrue(list[0].isEnabled)
    }

    func testIsActiveMatchesTheExactSwitchboard() {
        var list = rules(["one", "two"])
        list[0].isEnabled = false
        let scenario = MapLocalScenario(name: "both", ruleIDs: list.map(\.id))
        XCTAssertFalse(
            MapLocalScenarioRunner.isActive(scenario, in: list),
            "one scenario rule is off, so the switchboard does not match"
        )

        var enabled = list
        for index in enabled.indices { enabled[index].isEnabled = true }
        XCTAssertTrue(MapLocalScenarioRunner.isActive(scenario, in: enabled))
    }

    @MainActor
    func testTurnOffClearsEveryRuleAndTheActiveScenario() {
        let store = RuleStore()
        let first = MapLocalRule(name: "one", url: "a/*")
        let second = MapLocalRule(name: "two", url: "b/*")
        store.addMapLocalRule(first)
        store.addMapLocalRule(second)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [first.id]))

        store.activateMapLocalScenario(id: store.mapLocalScenarios[0].id)
        XCTAssertEqual(store.activeMapLocalScenarioID, store.mapLocalScenarios[0].id)
        XCTAssertEqual(store.mapLocalRules.map(\.isEnabled), [true, false])

        let disabled = store.turnOffMapLocalRules()

        XCTAssertEqual(disabled, 1)
        XCTAssertTrue(store.mapLocalRules.allSatisfy { !$0.isEnabled },
                      "Turn off leaves no rule from any scenario running")
        XCTAssertNil(store.activeMapLocalScenarioID)
    }

    @MainActor
    func testNewRuleStartsOffWhileAScenarioIsActive() {
        let store = RuleStore()
        let member = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(member)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [member.id]))
        store.activateMapLocalScenario(id: store.mapLocalScenarios[0].id)

        let added = MapLocalRule(name: "two", isEnabled: true, url: "b/*")
        store.addMapLocalRule(added)

        XCTAssertFalse(store.mapLocalRules[1].isEnabled,
                       "an outsider added while a scenario runs must not answer a request")
    }

    @MainActor
    func testRemovingTheActiveScenarioClearsTheActiveID() {
        let store = RuleStore()
        let rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [rule.id]))
        store.activateMapLocalScenario(id: store.mapLocalScenarios[0].id)

        store.removeMapLocalScenario(id: store.mapLocalScenarios[0].id)

        XCTAssertNil(store.activeMapLocalScenarioID)
        XCTAssertTrue(store.mapLocalRules[0].isEnabled, "Delete keeps the rules themselves")
    }

    @MainActor
    func testStoreSavesReplacesAndRemovesScenarios() {
        let store = RuleStore()
        let rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)

        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [rule.id]))
        XCTAssertEqual(store.mapLocalScenarios.map(\.name), ["visit"])

        let sameName = MapLocalScenario(name: "Visit", ruleIDs: [])
        store.saveMapLocalScenario(sameName)
        XCTAssertEqual(store.mapLocalScenarios.count, 1, "a same-name capture replaces instead of duplicating")
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [])
        XCTAssertEqual(store.mapLocalScenarios[0].name, "Visit")

        store.removeMapLocalScenario(id: store.mapLocalScenarios[0].id)
        XCTAssertTrue(store.mapLocalScenarios.isEmpty)
    }

    @MainActor
    func testRenameKeepsTheScenarioIdentityAndRejectsCollisions() {
        let store = RuleStore()
        let rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [rule.id]))
        store.saveMapLocalScenario(MapLocalScenario(name: "empty-cart", ruleIDs: []))
        let visitID = store.mapLocalScenarios[0].id

        XCTAssertTrue(store.renameMapLocalScenario(id: visitID, to: "  visit two  "))
        XCTAssertEqual(store.mapLocalScenarios[0].id, visitID, "renaming keeps the identifier")
        XCTAssertEqual(store.mapLocalScenarios[0].name, "visit two")
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [rule.id])

        XCTAssertFalse(store.renameMapLocalScenario(id: visitID, to: "Empty-Cart"),
                       "a name another scenario owns must not overwrite it")
        XCTAssertEqual(store.mapLocalScenarios[0].name, "visit two")
        XCTAssertFalse(store.renameMapLocalScenario(id: visitID, to: "   "))
    }

    @MainActor
    func testScenariosSurviveASecondStore() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleKitScenarioTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")
        let store = RuleStore(persistenceURL: url)
        let rule = MapLocalRule(name: "one", url: "a/*")
        store.addMapLocalRule(rule)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [rule.id]))
        store.flushRulesToDisk()

        let reloaded = RuleStore(persistenceURL: url)
        XCTAssertEqual(reloaded.mapLocalScenarios.map(\.name), ["visit"])
        XCTAssertEqual(reloaded.mapLocalScenarios.first?.ruleIDs, [rule.id])

        let applied = reloaded.activateMapLocalScenario(id: reloaded.mapLocalScenarios[0].id)
        XCTAssertEqual(applied, 1)
        XCTAssertTrue(reloaded.mapLocalRules[0].isEnabled)
    }

    func testRuleFileWrittenBeforeScenariosStillLoads() throws {
        let file = RuleFile(
            isMapLocalEnabled: false,
            mapLocalRules: [MapLocalRule(name: "kept", url: "api.example.com/*")]
        )
        let encoded = try JSONEncoder().encode(file)
        var object = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: encoded) as? [String: Any]
        )
        object.removeValue(forKey: "mapLocalScenarios")
        let legacyData = try JSONSerialization.data(withJSONObject: object)

        let decoded = try JSONDecoder().decode(RuleFile.self, from: legacyData)

        XCTAssertEqual(decoded.mapLocalRules.map(\.name), ["kept"])
        XCTAssertFalse(decoded.isMapLocalEnabled)
        XCTAssertTrue(decoded.mapLocalScenarios.isEmpty)
        XCTAssertNil(decoded.activeMapLocalScenarioID, "an older file has no scenario running")
    }
}


final class MapLocalScenarioAssignmentTests: XCTestCase {
    @MainActor
    func testEditorCheckboxesReplaceOnlyThisRulesMembership() {
        let store = RuleStore()
        let consultation = MapLocalRule(name: "consultation", url: "api.example.com/consultation/*")
        let prescription = MapLocalRule(name: "prescription", url: "api.example.com/prescription/*")
        store.addMapLocalRule(consultation)
        store.addMapLocalRule(prescription)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [consultation.id]))
        store.saveMapLocalScenario(MapLocalScenario(name: "lookup", ruleIDs: [prescription.id]))

        // The checkboxes are the whole truth: checking "visit" adds the rule there and
        // unchecking "lookup" removes it from that scenario.
        store.setMapLocalScenarios([store.mapLocalScenarios[0].id], forRule: prescription.id)
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [consultation.id, prescription.id])
        XCTAssertEqual(store.mapLocalScenarios[1].ruleIDs, [])

        // Unchecking every scenario removes the rule from both.
        store.setMapLocalScenarios([], forRule: prescription.id)
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [consultation.id])
        XCTAssertEqual(store.mapLocalScenarios[1].ruleIDs, [])
    }

    @MainActor
    func testNewScenarioNameExtendsAnExistingNameInsteadOfReplacingIt() {
        let store = RuleStore()
        let first = MapLocalRule(name: "first", url: "a.example.com/*")
        let second = MapLocalRule(name: "second", url: "b.example.com/*")
        store.addMapLocalRule(first)
        store.addMapLocalRule(second)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [first.id]))

        store.addRuleToScenario(second.id, named: "Visit")

        XCTAssertEqual(store.mapLocalScenarios.count, 1, "a case-insensitive name match extends the scenario")
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [first.id, second.id])

        store.addRuleToScenario(second.id, named: "  ")
        XCTAssertEqual(store.mapLocalScenarios.count, 1, "a blank name creates nothing")

        store.addRuleToScenario(second.id, named: "lookup")
        XCTAssertEqual(store.mapLocalScenarios.map(\.name), ["visit", "lookup"])
        XCTAssertEqual(store.mapLocalScenarios[1].ruleIDs, [second.id])
    }

    @MainActor
    func testJoiningAScenarioSwapsOutTheRuleForTheSameEndpoint() {
        let store = RuleStore()
        let ok = MapLocalRule(name: "consult-ok", method: MethodMatch("GET"), url: "consultation/*")
        let slow = MapLocalRule(name: "consult-slow", method: MethodMatch("GET"), url: "consultation/*")
        store.addMapLocalRule(ok)
        store.addMapLocalRule(slow)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [ok.id]))
        let visitID = store.mapLocalScenarios[0].id

        let swaps = store.setMapLocalScenarios([visitID], forRule: slow.id)

        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [slow.id],
                       "one scenario keeps one rule per endpoint")
        XCTAssertEqual(swaps.count, 1)
        XCTAssertEqual(swaps[0].scenarioID, visitID)
        XCTAssertEqual(swaps[0].replacedRuleID, ok.id)
        XCTAssertEqual(swaps[0].replacedRuleName, "consult-ok")
        XCTAssertEqual(swaps[0].addedRuleID, slow.id)
        XCTAssertEqual(store.mapLocalRules.map(\.isEnabled), [true, true],
                       "the rule that left the scenario is still a normal, enabled rule")
    }

    @MainActor
    func testSwapIgnoresADifferentMethodAndOtherScenarios() {
        let store = RuleStore()
        let getRule = MapLocalRule(name: "get", method: MethodMatch("GET"), url: "consultation/*")
        let postRule = MapLocalRule(name: "post", method: MethodMatch("POST"), url: "consultation/*")
        store.addMapLocalRule(getRule)
        store.addMapLocalRule(postRule)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [getRule.id]))
        store.saveMapLocalScenario(MapLocalScenario(name: "lookup", ruleIDs: [postRule.id]))

        let bothScenarios = Set(store.mapLocalScenarios.map(\.id))
        let swaps = store.setMapLocalScenarios(bothScenarios, forRule: postRule.id)

        XCTAssertTrue(swaps.isEmpty, "a POST and a GET are different endpoints")
        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [getRule.id, postRule.id])
        XCTAssertEqual(store.mapLocalScenarios[1].ruleIDs, [postRule.id])
    }

    @MainActor
    func testUndoSwapRestoresMembershipAndTheActiveSwitchboard() {
        let store = RuleStore()
        let ok = MapLocalRule(name: "consult-ok", method: MethodMatch("GET"), url: "consultation/*")
        let slow = MapLocalRule(name: "consult-slow", method: MethodMatch("GET"), url: "consultation/*")
        store.addMapLocalRule(ok)
        store.addMapLocalRule(slow)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [ok.id]))
        let visitID = store.mapLocalScenarios[0].id
        store.activateMapLocalScenario(id: visitID)

        let swaps = store.setMapLocalScenarios([visitID], forRule: slow.id)
        XCTAssertEqual(store.mapLocalRules.map(\.isEnabled), [false, true],
                       "the active scenario switches to the rule that replaced it")
        XCTAssertEqual(store.activeMapLocalScenarioID, visitID)

        for swap in swaps {
            store.undoMapLocalScenarioSwap(swap)
        }

        XCTAssertEqual(store.mapLocalScenarios[0].ruleIDs, [ok.id])
        XCTAssertEqual(store.mapLocalRules.map(\.isEnabled), [true, false])
        XCTAssertEqual(store.activeMapLocalScenarioID, visitID)
    }

    @MainActor
    func testDriftSurvivesAReload() {
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("RuleKitDriftTests-\(UUID().uuidString)", isDirectory: true)
            .appendingPathComponent("rules.json")
        let store = RuleStore(persistenceURL: url)
        let first = MapLocalRule(name: "one", method: MethodMatch("GET"), url: "a/*")
        let second = MapLocalRule(name: "two", method: MethodMatch("GET"), url: "b/*")
        store.addMapLocalRule(first)
        store.addMapLocalRule(second)
        store.saveMapLocalScenario(MapLocalScenario(name: "visit", ruleIDs: [first.id]))
        store.activateMapLocalScenario(id: store.mapLocalScenarios[0].id)
        store.setMapLocalRule(id: second.id, enabled: true)
        store.flushRulesToDisk()

        let reloaded = RuleStore(persistenceURL: url)

        XCTAssertEqual(reloaded.activeMapLocalScenarioID, reloaded.mapLocalScenarios[0].id,
                       "a manual toggle must not make the app forget which scenario is running")
        XCTAssertFalse(
            reloaded.isMapLocalScenarioActive(reloaded.mapLocalScenarios[0]),
            "the switchboard no longer matches, which is what makes the scenario read as modified"
        )
    }

    func testUntitledNamesSkipNamesAlreadyInUse() {
        XCTAssertEqual(MapLocalRuleNaming.untitled(existingNames: []), "Untitled Rule")
        XCTAssertEqual(MapLocalRuleNaming.untitled(existingNames: ["other"]), "Untitled Rule")
        XCTAssertEqual(MapLocalRuleNaming.untitled(existingNames: ["Untitled Rule"]), "Untitled Rule 2")
        XCTAssertEqual(
            MapLocalRuleNaming.untitled(existingNames: ["untitled rule 2", "Untitled Rule"]),
            "Untitled Rule 3"
        )
    }

    func testEndpointIdentityIgnoresMatchStyleAndDestination() {
        let wildcard = MapLocalRule(name: "one", method: MethodMatch("GET"), url: "consultation/*")
        let exact = MapLocalRule(
            name: "two",
            method: MethodMatch("get"),
            url: " consultation/* ",
            matchStyle: .exact,
            destination: .directory("/tmp")
        )

        XCTAssertEqual(wildcard.endpoint, exact.endpoint)
        XCTAssertEqual(wildcard.endpoint.label, "GET consultation/*")
        XCTAssertNotEqual(
            wildcard.endpoint,
            MapLocalRule(name: "three", method: MethodMatch("POST"), url: "consultation/*").endpoint
        )
    }
}
