import XCTest
import NIOHTTP1
@testable import ProxyKit
@testable import FlowKit

final class FlowRecorderCappingTests: XCTestCase {
    func testStreamingResponseDetection() {
        var mjpegHeaders = FlowKit.HTTPHeaders()
        mjpegHeaders["Content-Type"] = "multipart/x-mixed-replace; boundary=--frame"
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: mjpegHeaders))

        var sseHeaders = FlowKit.HTTPHeaders()
        sseHeaders["Content-Type"] = "text/event-stream; charset=utf-8"
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: sseHeaders))

        var videoChunked = FlowKit.HTTPHeaders()
        videoChunked["Content-Type"] = "video/mp4"
        videoChunked["Transfer-Encoding"] = "chunked"
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: videoChunked))

        var videoNoLength = FlowKit.HTTPHeaders()
        videoNoLength["Content-Type"] = "video/webm"
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: videoNoLength))

        var audioNoLength = FlowKit.HTTPHeaders()
        audioNoLength["Content-Type"] = "audio/mpeg"
        XCTAssertTrue(FlowRecorder.isStreamingResponse(headers: audioNoLength))

        var regularHtml = FlowKit.HTTPHeaders()
        regularHtml["Content-Type"] = "text/html"
        regularHtml["Content-Length"] = "1024"
        XCTAssertFalse(FlowRecorder.isStreamingResponse(headers: regularHtml))

        var videoWithLength = FlowKit.HTTPHeaders()
        videoWithLength["Content-Type"] = "video/mp4"
        videoWithLength["Content-Length"] = "5000000"
        XCTAssertFalse(FlowRecorder.isStreamingResponse(headers: videoWithLength))
    }

    func testCapturedResponseBodyStaysCappedForStandardResponse() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 1024
        )
        var emittedSnapshots: [Flow] = []
        let initialFlow = Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/file")
        )
        let recorder = FlowRecorder(flow: initialFlow, configuration: config) { flow in
            emittedSnapshots.append(flow)
        }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "application/octet-stream")
        nioHeaders.add(name: "Content-Length", value: "2048")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: nioHeaders)
        recorder.responseHead(head)

        // Append 2048 bytes of data in two chunks
        recorder.appendResponseBody(Data(repeating: 0x41, count: 800))
        recorder.appendResponseBody(Data(repeating: 0x42, count: 1248))
        recorder.complete()

        let current = recorder.current
        XCTAssertEqual(current.response?.body.count, 1024, "captured body should not exceed 1024 bytes")
        XCTAssertEqual(current.responseBodyTruncated, true)
        XCTAssertNil(current.isStreamingResponse)
    }

    func testCapturedResponseBodyStaysCappedForStreamingResponse() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 1024 * 1024,
            streamingBodyCaptureBytes: 512
        )
        var emittedSnapshots: [Flow] = []
        let initialFlow = Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/stream")
        )
        let recorder = FlowRecorder(flow: initialFlow, configuration: config) { flow in
            emittedSnapshots.append(flow)
        }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "multipart/x-mixed-replace; boundary=--myboundary")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: nioHeaders)
        recorder.responseHead(head)

        XCTAssertEqual(recorder.current.isStreamingResponse, true)

        // Stream 4 chunks of 300 bytes (1200 bytes total)
        for _ in 0..<4 {
            recorder.appendResponseBody(Data(repeating: 0xAA, count: 300))
        }
        recorder.complete()

        let current = recorder.current
        XCTAssertEqual(current.response?.body.count, 512, "captured streaming body should not exceed streaming cap of 512 bytes")
        XCTAssertEqual(current.responseBodyTruncated, true)
        XCTAssertEqual(current.isStreamingResponse, true)
    }

    func testLongLivedMediaTransitionsToStreamingCap() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 4096,
            streamingBodyCaptureBytes: 512
        )
        let initialFlow = Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/video.mp4")
        )
        let recorder = FlowRecorder(flow: initialFlow, configuration: config) { _ in }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "video/mp4")
        nioHeaders.add(name: "Content-Length", value: "1000000")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: nioHeaders)
        recorder.responseHead(head)

        // Not streaming initially because Content-Length is provided
        XCTAssertNil(recorder.current.isStreamingResponse)

        // Feed chunks exceeding streaming cap
        recorder.appendResponseBody(Data(repeating: 0x01, count: 600))
        recorder.appendResponseBody(Data(repeating: 0x02, count: 600))
        recorder.complete()

        let current = recorder.current
        XCTAssertEqual(current.isStreamingResponse, true, "long-lived media should transition to streaming")
        XCTAssertEqual(current.response?.body.count, 512, "captured body should be capped at streaming cap")
        XCTAssertEqual(current.responseBodyTruncated, true)
    }

    func testBodyDrivenEmitsStopWhenCapHitOrLiveLimitExceeded() {
        let config = ProxyConfiguration(
            maxCapturedResponseBodyBytes: 10 * 1024,
            streamingBodyCaptureBytes: 256,
            liveBodyEmitBytes: 512
        )
        var emitCount = 0
        let initialFlow = Flow(
            request: HTTPRequest(method: "GET", scheme: "http", host: "example.com", port: 80, path: "/stream")
        )
        let recorder = FlowRecorder(flow: initialFlow, configuration: config) { _ in
            emitCount += 1
        }

        var nioHeaders = NIOHTTP1.HTTPHeaders()
        nioHeaders.add(name: "Content-Type", value: "text/event-stream")
        let head = HTTPResponseHead(version: .http1_1, status: .ok, headers: nioHeaders)
        recorder.responseHead(head) // Emits responseHead snapshot

        let headEmits = emitCount

        // Send 50 chunks of 50 bytes (2500 bytes total, far exceeding streaming cap 256)
        for _ in 0..<50 {
            recorder.appendResponseBody(Data(repeating: 0x55, count: 50))
        }

        let bodyEmits = emitCount - headEmits
        // Intermediate body emissions should stop once capped! Should not emit 50 times.
        XCTAssertLessThanOrEqual(bodyEmits, 2, "intermediate body emits should stop once cap is hit")

        // Completing the flow must always emit a final snapshot
        let beforeComplete = emitCount
        recorder.complete()
        XCTAssertEqual(emitCount, beforeComplete + 1, "complete() must always emit the final snapshot")
    }

    func testRequestBodyTruncation() {
        let config = ProxyConfiguration(
            maxCapturedRequestBodyBytes: 256
        )
        let largeBody = Data(repeating: 0x5A, count: 1024)
        let flow = Flow(
            request: HTTPRequest(
                method: "POST",
                scheme: "http",
                host: "example.com",
                port: 80,
                path: "/submit",
                body: largeBody
            )
        )
        let recorder = FlowRecorder(flow: flow, configuration: config) { _ in }

        XCTAssertEqual(recorder.current.request.body.count, 256)
        XCTAssertEqual(recorder.current.requestBodyTruncated, true)
    }
}
