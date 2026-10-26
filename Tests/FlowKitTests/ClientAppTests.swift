import XCTest
@testable import FlowKit

final class ClientAppTests: XCTestCase {
    func testSessionDecodesLegacyNameAndMissingAttribution() throws {
        let captured = flow(client: nil)
        var record = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(captured)) as? [String: Any])
        record["clientApp"] = "curl"
        let legacy = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertEqual(legacy.clientApp?.name, "curl")
        XCTAssertEqual(legacy.id, captured.id)
        XCTAssertEqual(legacy.request, captured.request)
        XCTAssertTrue(FlowFilter(sidebarSelection: .app("curl")).matches(legacy))

        record.removeValue(forKey: "clientApp")
        let unattributed = try JSONDecoder().decode(Flow.self, from: JSONSerialization.data(withJSONObject: record))
        XCTAssertNil(unattributed.clientApp)
        XCTAssertTrue(FlowFilter().matches(unattributed))
        XCTAssertFalse(FlowFilter(sidebarSelection: .app("curl")).matches(unattributed))
    }

    func testSessionRoundTripPreservesClientIdentity() throws {
        let client = ClientApp(
            name: "Browser", bundleIdentifier: "test.browser", path: "/Applications/Browser.app", pid: 123
        )
        let restored = try JSONDecoder().decode(Flow.self, from: JSONEncoder().encode(flow(client: client)))
        XCTAssertEqual(restored.clientApp, client)
        XCTAssertTrue(FlowFilter(sidebarSelection: .client(client.id)).matches(restored))
    }

    func testExactSelectionSeparatesNamesButGroupsProcessRestarts() {
        let client = ClientApp(
            name: "Browser", bundleIdentifier: "test.first", path: "/Applications/Browser.app", pid: 100
        )
        let restarted = ClientApp(
            name: "Browser", bundleIdentifier: "test.first", path: "/Applications/Browser.app", pid: 200
        )
        let unrelated = ClientApp(
            name: "Browser", bundleIdentifier: "test.second", path: "/Applications/Other.app", pid: 300
        )
        let confusingName = ClientApp(name: client.id)
        let chosen = flow(client: client)
        let later = flow(client: restarted)
        let other = flow(client: unrelated)
        let spoofed = flow(client: confusingName)
        let filter = FlowFilter(sidebarSelection: .client(client.id))
        XCTAssertEqual(filter.apply(to: [chosen, later, other, spoofed]).map(\.id), [chosen.id, later.id])

        let firstTool = ClientApp(name: "tool", path: "/opt/one/tool", pid: 400)
        let otherTool = ClientApp(name: "tool", path: "/opt/two/tool", pid: 500)
        XCTAssertFalse(FlowFilter(sidebarSelection: .client(firstTool.id)).matches(flow(client: otherTool)))
    }

    func testAppChoiceIntersectsTextMethodAndErrorFilters() {
        let client = ClientApp(
            name: "Browser", bundleIdentifier: "test.browser", path: "/Applications/Browser.app", pid: 123
        )
        var failed = flow(client: client)
        failed.error = "Connection refused"
        let successful = flow(client: client)
        var anotherApp = flow(client: ClientApp(name: "Another", bundleIdentifier: "test.another"))
        anotherApp.error = "Connection refused"
        var filter = FlowFilter(
            text: "example.test", method: "POST", onlyErrors: true, sidebarSelection: .client(client.id)
        )
        XCTAssertEqual(filter.apply(to: [failed, successful, anotherApp]).map(\.id), [failed.id])
        filter.method = "GET"
        XCTAssertFalse(filter.matches(failed))
        filter.method = "POST"
        filter.text = "missing.test"
        XCTAssertFalse(filter.matches(failed))
        for selector in ["browser", "test.browser", "/Applications/Browser.app"] {
            XCTAssertTrue(FlowFilter(sidebarSelection: .app(selector)).matches(failed))
        }
    }

    private func flow(client: ClientApp?) -> Flow {
        Flow(
            request: HTTPRequest(method: "POST", scheme: "http", host: "example.test", port: 80, path: "/capture"),
            clientApp: client
        )
    }
}
