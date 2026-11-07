import XCTest
import LogKit
import Sentry
@testable import SentryKit

final class EventSanitizerTests: XCTestCase {
    private func makeEvent() -> Event {
        let event = Event(level: .error)
        event.message = SentryMessage(
            formatted: "request failed https://alice:pass@api.example.com/items?access_token=abc Authorization: Bearer abc123"
        )
        event.releaseName = "com.proxymaxx.app@1.0.0"
        event.dist = "42"
        event.environment = "production"

        let user = User()
        user.email = "alice@example.com"
        user.username = "alice"
        event.user = user

        let request = SentryRequest()
        request.url = "https://api.example.com/items?access_token=abc"
        event.request = request

        event.extra = ["password": "hunter2", "note": "hello"]
        event.tags = [
            "component": "ProxyKit.Engine",
            "password": "hunter2",
            "correlation_id": "abc-123",
            "unexpected": "drop-me",
        ]

        event.context = [
            "app": ["name": "ProxyMaxx", "version": "1.0.0", "device_app_hash": "secret"],
            "device": ["name": "Alice's MacBook", "model": "MacBookPro18,3"],
            "custom": ["token": "abc"],
        ]

        let exception = Exception(value: "password=hunter2 for https://example.com/x?token=abc", type: "ProxyFailure")
        let frame = Frame()
        frame.fileName = "/Users/alice/Projects/ProxyMaxx/Sources/AppModel.swift"
        frame.function = "start"
        frame.module = "/Users/alice/Projects/ProxyMaxx/ProxyMaxx.app/Contents/MacOS/ProxyMaxx"
        frame.contextLine = #"let token = "hunter2""#
        frame.preContext = ["api_key=abc"]
        frame.vars = ["token": "hunter2"]
        let stacktrace = SentryStacktrace(frames: [frame], registers: ["r0": "hunter2"])
        exception.stacktrace = stacktrace
        event.exceptions = [exception]

        let thread = SentryThread(threadId: 1)
        thread.name = "alice@example.com"
        thread.stacktrace = stacktrace
        event.threads = [thread]

        let image = DebugMeta()
        image.codeFile = "/Users/alice/Projects/ProxyMaxx/ProxyMaxx"
        event.debugMeta = [image]
        event.breadcrumbs = [Breadcrumb(level: .info, category: "http")]
        return event
    }

    func testProhibitedEventFieldsAreRemoved() throws {
        let event = try XCTUnwrap(EventSanitizer().sanitize(makeEvent()))
        XCTAssertNil(event.user)
        XCTAssertNil(event.request)
        XCTAssertNil(event.extra)
        XCTAssertTrue((event.breadcrumbs ?? []).isEmpty)
    }

    func testTagsAndContextUseAnAllowlist() throws {
        let event = try XCTUnwrap(EventSanitizer().sanitize(makeEvent()))
        XCTAssertEqual(event.tags?["component"], "ProxyKit.Engine")
        XCTAssertEqual(event.tags?["correlation_id"], "abc-123")
        XCTAssertNil(event.tags?["password"])
        XCTAssertNil(event.tags?["unexpected"])

        XCTAssertEqual(event.context?["app"]?["name"] as? String, "ProxyMaxx")
        XCTAssertNil(event.context?["app"]?["device_app_hash"])
        XCTAssertNil(event.context?["device"]?["name"])
        XCTAssertEqual(event.context?["device"]?["model"] as? String, "MacBookPro18,3")
        XCTAssertNil(event.context?["custom"])
    }

    func testMessagesAndExceptionsAreRedacted() throws {
        let event = try XCTUnwrap(EventSanitizer().sanitize(makeEvent()))
        let message = try XCTUnwrap(event.message?.formatted)
        XCTAssertFalse(message.contains("Bearer"))
        XCTAssertFalse(message.contains("access_token=abc"))
        XCTAssertFalse(message.contains("alice"))
        XCTAssertFalse(Redactor.containsSensitiveData(message))

        let exception = try XCTUnwrap(event.exceptions?.first)
        XCTAssertFalse(exception.value?.contains("hunter2") ?? true)
        XCTAssertFalse(Redactor.containsSensitiveData(exception.value ?? ""))
    }

    func testStackFramesKeepOnlySafeContext() throws {
        let event = try XCTUnwrap(EventSanitizer().sanitize(makeEvent()))
        let frame = try XCTUnwrap(event.exceptions?.first?.stacktrace?.frames.first)
        XCTAssertEqual(frame.fileName, "AppModel.swift")
        XCTAssertEqual(frame.module, "ProxyMaxx")
        XCTAssertNil(frame.contextLine)
        XCTAssertNil(frame.preContext)
        XCTAssertNil(frame.vars)
        XCTAssertEqual(event.exceptions?.first?.stacktrace?.registers, [:])
    }

    func testThreadNamesAndDebugImagePathsAreSanitized() throws {
        let event = try XCTUnwrap(EventSanitizer().sanitize(makeEvent()))
        XCTAssertEqual(event.threads?.first?.name, "[redacted-email]")
        XCTAssertEqual(event.debugMeta?.first?.codeFile, "ProxyMaxx")
    }

    func testEventWithoutSensitiveDataSurvives() throws {
        let event = Event(level: .error)
        event.message = SentryMessage(formatted: "Proxy engine failed to bind port 9090")
        let sanitized = try XCTUnwrap(EventSanitizer().sanitize(event))
        XCTAssertEqual(sanitized.message?.formatted, "Proxy engine failed to bind port 9090")
    }
}
