import XCTest
@testable import FlowKit

final class FlowFilterOptimizationTests: XCTestCase {
    private func makeFlow(
        url: String = "https://api.example.com/v1/users",
        method: String = "GET",
        statusCode: Int = 200,
        error: String? = nil,
        isPinned: Bool = false
    ) -> Flow {
        let uri = URL(string: url)!
        let scheme = uri.scheme ?? "https"
        let host = uri.host ?? "api.example.com"
        let port = uri.port ?? (scheme == "https" ? 443 : 80)
        let path = uri.path.isEmpty ? "/" : uri.path

        let req = HTTPRequest(
            method: method,
            scheme: scheme,
            host: host,
            port: port,
            path: path,
            httpVersion: "HTTP/1.1",
            headers: HTTPHeaders(),
            body: Data()
        )
        let res = HTTPResponse(
            statusCode: statusCode,
            httpVersion: "HTTP/1.1",
            headers: HTTPHeaders(),
            body: Data()
        )
        return Flow(
            id: UUID(),
            request: req,
            response: res,
            error: error,
            isPinned: isPinned
        )
    }

    func testFilterMatchesURLCaseInsensitiveWithoutAllocation() {
        let filter = FlowFilter(text: "USERS")
        let flow = makeFlow(url: "https://api.example.com/v1/users")
        XCTAssertTrue(filter.matches(flow))

        let nonMatching = makeFlow(url: "https://api.example.com/v1/products")
        XCTAssertFalse(filter.matches(nonMatching))
    }

    func testFilterMatchesHostCaseInsensitive() {
        let filter = FlowFilter(text: "EXAMPLE.COM")
        let flow = makeFlow(url: "https://api.example.com/test")
        XCTAssertTrue(filter.matches(flow))
    }

    func testFilterMatchesMethod() {
        let postFlow = makeFlow(method: "POST")
        let getFlow = makeFlow(method: "GET")

        let filter = FlowFilter(method: "post")
        XCTAssertTrue(filter.matches(postFlow))
        XCTAssertFalse(filter.matches(getFlow))

        let allFilter = FlowFilter(method: "All")
        XCTAssertTrue(allFilter.matches(postFlow))
        XCTAssertTrue(allFilter.matches(getFlow))
    }

    func testFilterMatchesStatusCode() {
        let flow404 = makeFlow(statusCode: 404)
        let flow200 = makeFlow(statusCode: 200)

        let filter = FlowFilter(text: "404")
        XCTAssertTrue(filter.matches(flow404))
        XCTAssertFalse(filter.matches(flow200))
    }

    func testFilterOnlyErrors() {
        let errorFlow = makeFlow(error: "Connection reset")
        let status500 = makeFlow(statusCode: 500)
        let status200 = makeFlow(statusCode: 200)

        let errorFilter = FlowFilter(onlyErrors: true)
        XCTAssertTrue(errorFilter.matches(errorFlow))
        XCTAssertTrue(errorFilter.matches(status500))
        XCTAssertFalse(errorFilter.matches(status200))
    }

    func testFilterAppliesToFlowCollection() {
        let flows = [
            makeFlow(url: "https://a.com/one", method: "GET"),
            makeFlow(url: "https://a.com/two", method: "POST"),
            makeFlow(url: "https://b.com/three", method: "GET")
        ]

        let filter = FlowFilter(text: "two")
        let filtered = filter.apply(to: flows)
        XCTAssertEqual(filtered.count, 1)
        XCTAssertEqual(filtered.first?.url, "https://a.com/two")
    }
}
