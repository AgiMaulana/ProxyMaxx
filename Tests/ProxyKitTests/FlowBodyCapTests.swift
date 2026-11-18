import XCTest
import NIOCore
import NIOHTTP1
@testable import FlowKit
@testable import ProxyKit

final class FlowBodyCapTests: XCTestCase {
    private func makeRequest(bodySize: Int) -> HTTPRequest {
        let body = Data(repeating: 0x41, count: bodySize)
        return HTTPRequest(
            method: "POST",
            scheme: "http",
            host: "example.com",
            port: 80,
            path: "/upload",
            headers: HTTPHeaders([
                Header(name: "Host", value: "example.com"),
                Header(name: "Content-Length", value: "\(bodySize)")
            ]),
            body: body
        )
    }

    func testRequestBodyCapTruncatesAndSetsFlag() {
        let config = ProxyConfiguration(maxCapturedRequestBodyBytes: 1024)
        var emitted: [Flow] = []
        let initialFlow = Flow(
            request: makeRequest(bodySize: 2048),
            timing: FlowTiming()
        )

        let recorder = FlowRecorder(
            flow: initialFlow,
            configuration: config,
            onEmit: { emitted.append($0) }
        )

        XCTAssertTrue(recorder.current.isRequestBodyTruncated)
        XCTAssertEqual(recorder.current.request.body.count, 1024)
    }

    func testResponseBodyCapTruncatesRegularResponse() {
        let config = ProxyConfiguration(maxCapturedResponseBodyBytes: 2048)
        var emitted: [Flow] = []
        let recorder = FlowRecorder(
            flow: Flow(request: makeRequest(bodySize: 10), timing: FlowTiming()),
            configuration: config,
            onEmit: { emitted.append($0) }
        )

        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Type", value: "application/json")
        recorder.responseHead(head)

        // Stream 4 KiB into a 2 KiB budget
        recorder.appendResponseBody(Data(repeating: 0x42, count: 1024))
        recorder.appendResponseBody(Data(repeating: 0x42, count: 1024))
        recorder.appendResponseBody(Data(repeating: 0x42, count: 1024))
        recorder.appendResponseBody(Data(repeating: 0x42, count: 1024))
        recorder.complete()

        let current = recorder.current
        XCTAssertTrue(current.isResponseBodyTruncated)
        XCTAssertEqual(current.response?.body.count, 2048)
        XCTAssertNil(current.isStreamingResponse)
        XCTAssertTrue(current.isCompleted)
    }

    func testStreamingResponseDetectedAndCappedAtSmallerBudget() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 1024 * 1024,
            streamingBodyCaptureBytes: 1024 // 1 KiB streaming cap
        )
        var emitted: [Flow] = []
        let recorder = FlowRecorder(
            flow: Flow(request: makeRequest(bodySize: 10), timing: FlowTiming()),
            configuration: config,
            onEmit: { emitted.append($0) }
        )

        // multipart/x-mixed-replace (typical CCTV / MJPEG stream)
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Type", value: "multipart/x-mixed-replace; boundary=--frame")
        recorder.responseHead(head)

        XCTAssertEqual(recorder.current.isStreamingResponse, true)

        // Send 10 KiB of frames
        recorder.appendResponseBody(Data(repeating: 0x58, count: 10 * 1024))
        recorder.complete()

        let current = recorder.current
        XCTAssertEqual(current.isStreamingResponse, true)
        XCTAssertTrue(current.isResponseBodyTruncated)
        XCTAssertEqual(current.response?.body.count, 1024)
    }

    func testSSEStreamingResponseDetected() {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Type", value: "text/event-stream")
        let headers = FlowKit.HTTPHeaders(nio: head.headers)
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: headers))
    }

    func testChunkedVideoStreamingResponseDetected() {
        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Type", value: "video/mp4")
        head.headers.add(name: "Transfer-Encoding", value: "chunked")
        let headers = FlowKit.HTTPHeaders(nio: head.headers)
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: headers))
    }

    func testBodyDrivenEmitsStopWhenCappedOrLimitExceeded() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 512,
            streamingBodyCaptureBytes: 512,
            liveBodyEmitBytes: 512
        )
        var emitted: [Flow] = []
        let recorder = FlowRecorder(
            flow: Flow(request: makeRequest(bodySize: 10), timing: FlowTiming()),
            configuration: config,
            onEmit: { emitted.append($0) }
        )

        var head = HTTPResponseHead(version: .http1_1, status: .ok)
        head.headers.add(name: "Content-Type", value: "text/plain")
        recorder.responseHead(head)

        // Append 100 chunks of 100 bytes each
        for _ in 1...100 {
            recorder.appendResponseBody(Data(repeating: 0x5a, count: 100))
        }

        // Only initial/early emits should happen while under cap; body emits stop once capped.
        let emitsBeforeComplete = emitted.count
        XCTAssertLessThanOrEqual(emitsBeforeComplete, 3)

        // When complete() is called, the final snapshot MUST be emitted!
        recorder.complete()
        XCTAssertEqual(emitted.count, emitsBeforeComplete + 1)
        XCTAssertTrue(emitted.last?.isCompleted == true)
        XCTAssertTrue(emitted.last?.isResponseBodyTruncated == true)
    }

    func testBackwardCompatibilityDecodingWithoutTruncationFields() throws {
        // Encode a valid Flow, remove truncation/streaming fields, and ensure it decodes cleanly
        let originalFlow = Flow(
            request: makeRequest(bodySize: 10),
            timing: FlowTiming()
        )
        let encoder = JSONEncoder()
        let encodedData = try encoder.encode(originalFlow)
        var jsonObject = try JSONSerialization.jsonObject(with: encodedData) as! [String: Any]
        jsonObject.removeValue(forKey: "requestBodyTruncated")
        jsonObject.removeValue(forKey: "responseBodyTruncated")
        jsonObject.removeValue(forKey: "isStreamingResponse")
        let legacyData = try JSONSerialization.data(withJSONObject: jsonObject)

        let flow = try JSONDecoder().decode(Flow.self, from: legacyData)
        XCTAssertFalse(flow.isRequestBodyTruncated)
        XCTAssertFalse(flow.isResponseBodyTruncated)
        XCTAssertNil(flow.isStreamingResponse)
        XCTAssertFalse(flow.isCompleted)
    }
}
