import XCTest
@testable import CodeGenKit
import FlowKit

final class CurlCommandTests: XCTestCase {
    func testPlainGetNeedsOnlyTheURL() {
        let request = HTTPRequest(method: "GET", scheme: "https", host: "example.com", port: 443, path: "/a?b=1")
        XCTAssertEqual(CurlCommand.make(from: request), "curl 'https://example.com/a?b=1'")
    }

    func testKeepsANonDefaultPort() {
        let request = HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 8080, path: "/health")
        XCTAssertEqual(CurlCommand.make(from: request), "curl 'http://example.com:8080/health'")
    }

    func testPostCarriesHeadersAndBody() {
        var headers = HTTPHeaders()
        headers.add(name: "Content-Type", value: "application/json")
        headers.add(name: "Host", value: "example.com")
        headers.add(name: "Content-Length", value: "18")
        headers.add(name: "X-Trace", value: "abc")
        let request = HTTPRequest(
            method: "POST",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: "/v1/items",
            headers: headers,
            body: Data(#"{"name":"O'Brien"}"#.utf8)
        )

        let expected = """
        curl --request POST 'https://example.com/v1/items' \\
          --header 'Content-Type: application/json' \\
          --header 'X-Trace: abc' \\
          --data-raw '{"name":"O'\\''Brien"}'
        """
        XCTAssertEqual(CurlCommand.make(from: request), expected)
    }

    func testGetWithABodyKeepsItsMethod() {
        let request = HTTPRequest(
            method: "GET",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: "/search",
            body: Data("q=x".utf8)
        )

        let expected = """
        curl --request GET 'https://example.com/search' \\
          --data-raw 'q=x'
        """
        XCTAssertEqual(CurlCommand.make(from: request), expected)
    }

    func testEmptyPostHasNoDataArgument() {
        let request = HTTPRequest(method: "POST", scheme: "https", host: "example.com", port: 443, path: "/x")
        XCTAssertEqual(CurlCommand.make(from: request), "curl --request POST 'https://example.com/x'")
    }

    func testNonUTF8BodyIsEscapedByteForByte() {
        let request = HTTPRequest(
            method: "POST",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: "/upload",
            body: Data([0x00, 0x27, 0x5C, 0x41])
        )

        let expected = """
        curl --request POST 'http://example.com/upload' \\
          --data-binary $'\\x00\\'\\\\A'
        """
        XCTAssertEqual(CurlCommand.make(from: request), expected)
    }

    func testDuplicateHeadersAreAllKept() {
        var headers = HTTPHeaders()
        headers.add(name: "Accept", value: "text/html")
        headers.add(name: "Accept", value: "application/json")
        let request = HTTPRequest(
            method: "GET",
            scheme: "https",
            host: "example.com",
            port: 443,
            path: "/",
            headers: headers
        )

        let expected = """
        curl 'https://example.com/' \\
          --header 'Accept: text/html' \\
          --header 'Accept: application/json'
        """
        XCTAssertEqual(CurlCommand.make(from: request), expected)
    }

    func testFlowExtensionMatchesTheRequestRenderer() {
        let request = HTTPRequest(method: "DELETE", scheme: "https", host: "example.com", port: 443, path: "/v1/items/7")
        let flow = Flow(request: request)
        XCTAssertEqual(flow.curlCommand, CurlCommand.make(from: request))
        XCTAssertEqual(flow.curlCommand, "curl --request DELETE 'https://example.com/v1/items/7'")
    }
}
