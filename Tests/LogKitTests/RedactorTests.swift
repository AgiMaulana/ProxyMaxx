import XCTest
@testable import LogKit

final class RedactorTests: XCTestCase {
    func testAuthorizationHeaderIsRemoved() {
        let redacted = Redactor.redact("Authorization: Bearer abc123")
        XCTAssertEqual(redacted, "Authorization: [REDACTED]")
        XCTAssertFalse(Redactor.containsSensitiveData(redacted))
    }

    func testCookieHeadersAreRemoved() {
        let redacted = Redactor.redact("Cookie: session=abc; theme=dark\nSet-Cookie: token=xyz")
        XCTAssertFalse(redacted.contains("session=abc"))
        XCTAssertFalse(redacted.contains("token=xyz"))
        XCTAssertTrue(redacted.contains("Cookie: [REDACTED]"))
        XCTAssertTrue(redacted.contains("Set-Cookie: [REDACTED]"))
    }

    func testTokenAndAPIKeyFieldsAreRemoved() {
        XCTAssertEqual(Redactor.redact("access_token=abc"), "access_token=[REDACTED]")
        XCTAssertEqual(Redactor.redact("api_key: xyz"), "api_key: [REDACTED]")
        XCTAssertEqual(Redactor.redact(#""refresh_token":"abc""#), #""refresh_token":[REDACTED]"#)
    }

    func testPasswordFieldsAreRemoved() {
        XCTAssertEqual(Redactor.redact("password=hunter2"), "password=[REDACTED]")
        XCTAssertEqual(Redactor.redact("pwd: \"a b c\""), "pwd: [REDACTED]")
        XCTAssertEqual(Redactor.redact("client_secret=shh"), "client_secret=[REDACTED]")
    }

    func testURLQueryParametersAreRemoved() {
        let redacted = Redactor.redact("https://api.example.com/v1/items?access_token=abc&page=2")
        XCTAssertFalse(redacted.contains("access_token=abc"))
        XCTAssertFalse(redacted.contains("page=2"))
        XCTAssertTrue(redacted.contains("api.example.com"))
    }

    func testProxyCredentialsAreRemoved() {
        let redacted = Redactor.redact("proxy_user=alice proxy_password=s3cret")
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("s3cret"))
        XCTAssertTrue(redacted.contains("proxy_user=[REDACTED]"))
    }

    func testURLCredentialsAndPathAreRemoved() {
        let redacted = Redactor.redact("failed to fetch https://alice:pass@example.com/private/data?token=abc")
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertFalse(redacted.contains("pass"))
        XCTAssertFalse(redacted.contains("/private/data"))
        XCTAssertTrue(redacted.contains("https://example.com"))
    }

    func testHomeDirectoryAndEmailAreRemoved() {
        let redacted = Redactor.redact("/Users/alice/Library/Logs/0.log from alice@example.com")
        XCTAssertFalse(redacted.contains("alice"))
        XCTAssertTrue(redacted.contains("/Users/[redacted]/Library/Logs/0.log"))
        XCTAssertTrue(redacted.contains("[redacted-email]"))
    }

    func testSafeTextIsUnchanged() {
        let text = "ProxyKit.Engine failed to start on 127.0.0.1:9090"
        XCTAssertEqual(Redactor.redact(text), text)
        XCTAssertFalse(Redactor.containsSensitiveData(text))
    }

    func testRedactionIsIdempotent() {
        let samples = [
            "Authorization: Bearer abc",
            "https://example.com/private?token=abc",
            "password: hunter2",
            "/Users/alice/file.log",
        ]
        for sample in samples {
            let once = Redactor.redact(sample)
            XCTAssertEqual(Redactor.redact(once), once)
        }
    }

    func testResidualSensitiveDataIsDetected() {
        XCTAssertTrue(Redactor.containsSensitiveData("Authorization: Bearer abc"))
        XCTAssertTrue(Redactor.containsSensitiveData("access_token=abc"))
        XCTAssertTrue(Redactor.containsSensitiveData("?token=abc"))
        XCTAssertTrue(Redactor.containsSensitiveData("https://alice:pass@example.com"))
        XCTAssertTrue(Redactor.containsSensitiveData("/Users/alice/file"))
        XCTAssertTrue(Redactor.containsSensitiveData("alice@example.com"))
    }
}
