import XCTest
@testable import FlowKit

final class FlowCaptureCapTests: XCTestCase {
    func testOldSessionLogsDecodeWithoutTruncationFields() throws {
        // JSON representation of a Flow before Phase 1 (no truncation or streaming fields).
        let oldFlowJSON = """
        {
            "id": "A1B2C3D4-E5F6-7890-ABCD-EF1234567890",
            "request": {
                "method": "GET",
                "scheme": "http",
                "host": "example.com",
                "port": 80,
                "path": "/index.html",
                "httpVersion": "HTTP/1.1",
                "headers": {
                    "entries": [
                        {"name": "Host", "value": "example.com"}
                    ]
                },
                "body": ""
            },
            "response": {
                "statusCode": 200,
                "httpVersion": "HTTP/1.1",
                "headers": {
                    "entries": [
                        {"name": "Content-Type", "value": "text/html"}
                    ]
                },
                "body": "PGh0bWw+PC9odG1sPg=="
            },
            "timing": {
                "start": 700000000
            },
            "isIntercepted": false,
            "source": "local",
            "isPinned": false
        }
        """

        let decoder = JSONDecoder()
        let flow = try decoder.decode(Flow.self, from: Data(oldFlowJSON.utf8))

        XCTAssertEqual(flow.id, UUID(uuidString: "A1B2C3D4-E5F6-7890-ABCD-EF1234567890"))
        XCTAssertEqual(flow.statusCode, 200)
        XCTAssertNil(flow.requestBodyTruncated, "old flow should decode with nil requestBodyTruncated")
        XCTAssertNil(flow.responseBodyTruncated, "old flow should decode with nil responseBodyTruncated")
        XCTAssertNil(flow.isStreamingResponse, "old flow should decode with nil isStreamingResponse")
        XCTAssertFalse(flow.isRequestBodyTruncated)
        XCTAssertFalse(flow.isResponseBodyTruncated)
    }

    func testRoundTripFlowWithTruncationFields() throws {
        let flow = Flow(
            request: HTTPRequest(
                method: "POST",
                scheme: "https",
                host: "api.example.com",
                port: 443,
                path: "/upload",
                body: Data("capped-req".utf8)
            ),
            response: HTTPResponse(
                statusCode: 200,
                body: Data("capped-resp".utf8)
            ),
            requestBodyTruncated: true,
            responseBodyTruncated: true,
            isStreamingResponse: true
        )

        let encoder = JSONEncoder()
        let data = try encoder.encode(flow)

        let decoder = JSONDecoder()
        let decoded = try decoder.decode(Flow.self, from: data)

        XCTAssertEqual(decoded.requestBodyTruncated, true)
        XCTAssertEqual(decoded.responseBodyTruncated, true)
        XCTAssertEqual(decoded.isStreamingResponse, true)
        XCTAssertTrue(decoded.isRequestBodyTruncated)
        XCTAssertTrue(decoded.isResponseBodyTruncated)
    }
}
