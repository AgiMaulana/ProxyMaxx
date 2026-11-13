import XCTest
import Foundation
@testable import RuleKit

final class HARImportTests: XCTestCase {
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("HARImportTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    private let fixture = """
    {
      "log": {
        "version": "1.2",
        "creator": { "name": "fixture", "version": "1" },
        "entries": [
          {
            "request": {
              "method": "GET",
              "url": "https://api.example.test/v1/users?page=2",
              "headers": [{ "name": "Accept", "value": "application/json" }]
            },
            "response": {
              "status": 200,
              "statusText": "OK",
              "headers": [
                { "name": "Content-Type", "value": "application/json; charset=utf-8" },
                { "name": "Content-Encoding", "value": "gzip" },
                { "name": "Transfer-Encoding", "value": "chunked" }
              ],
              "content": {
                "size": 15,
                "mimeType": "application/json; charset=utf-8",
                "text": "{\\"users\\":[1,2]}"
              }
            }
          },
          {
            "request": {
              "method": "GET",
              "url": "https://cdn.example.test/logo.png"
            },
            "response": {
              "status": 200,
              "statusText": "OK",
              "headers": [{ "name": "Content-Type", "value": "image/png" }],
              "content": {
                "size": 4,
                "mimeType": "image/png",
                "encoding": "base64",
                "text": "aGVsbG8="
              }
            }
          },
          {
            "request": {
              "method": "GET",
              "url": "https://api.example.test/v1/redirect"
            },
            "response": {
              "status": 302,
              "statusText": "Found",
              "headers": [{ "name": "Location", "value": "/v1/users" }],
              "content": { "size": 0, "mimeType": "text/html" }
            }
          },
          {
            "request": { "method": "POST", "url": "https://api.example.test/v1/broken" }
          }
        ]
      }
    }
    """

    func testParseToleratesMissingFieldsAndCollectsEntries() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        XCTAssertEqual(entries.count, 4)
        XCTAssertEqual(entries[0].request?.method, "GET")
        XCTAssertEqual(entries[1].response?.content?.encoding, "base64")
        XCTAssertNil(entries[3].response)
    }

    func testMakeRuleFollowsFlowMappingConventions() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        let url = temporary.appendingPathComponent("response.json")
        let rule = try XCTUnwrap(HARImporter.makeRule(for: entries[0], responseFileURL: url))

        XCTAssertEqual(rule.name, "/v1/users")
        XCTAssertEqual(rule.method.displayName, "GET")
        XCTAssertEqual(rule.url, "api.example.test/v1/users?page=2")
        XCTAssertEqual(rule.matchStyle, .wildcard)
        XCTAssertTrue(rule.includePath)
        XCTAssertEqual(rule.destination, .file(url.path))
        XCTAssertEqual(rule.responseDelay, 0)
    }

    func testMakeRuleSkipsEntriesWithoutBodyOrURL() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        XCTAssertFalse(HARImporter.hasBody(entries[2]), "empty body is not usable")
        XCTAssertFalse(HARImporter.hasBody(entries[3]), "no response at all is not usable")
        XCTAssertNil(HARImporter.makeRule(for: entries[2], responseFileURL: temporary.appendingPathComponent("a.json")))
        XCTAssertNil(HARImporter.makeRule(for: entries[3], responseFileURL: temporary.appendingPathComponent("b.json")))
    }

    func testWriteResponseProducesFullMessageWithoutFramingHeaders() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        let url = temporary.appendingPathComponent("message.json")
        try HARImporter.writeResponse(for: entries[0], to: url)

        let content = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(content.hasPrefix("HTTP/1.1 200 OK\r\n"), content)
        XCTAssertTrue(content.contains("Content-Type: application/json; charset=utf-8"))
        XCTAssertFalse(content.contains("Content-Encoding"), "decoded body must not claim gzip")
        XCTAssertFalse(content.contains("Transfer-Encoding"))
        XCTAssertFalse(content.contains("Content-Length"))
        XCTAssertTrue(content.contains("\r\n\r\n{\n  \"users\" : [\n    1,\n    2\n  ]\n}"), content)
    }

    func testWriteResponseDecodesBase64Body() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        let url = temporary.appendingPathComponent("logo.png")
        try HARImporter.writeResponse(for: entries[1], to: url)

        let data = try Data(contentsOf: url)
        let content = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(data.starts(with: Data("HTTP/1.1 200 OK\r\n".utf8)), "count=\(data.count) content=\(content.debugDescription)")
        XCTAssertTrue(data.suffix(5).elementsEqual("hello".utf8), "content=\(content.debugDescription)")
    }

    func testWriteResponseRefusesExistingFile() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        let url = temporary.appendingPathComponent("existing.json")
        try Data("keep".utf8).write(to: url)
        XCTAssertThrowsError(try HARImporter.writeResponse(for: entries[0], to: url))
        XCTAssertEqual(try String(contentsOf: url, encoding: .utf8), "keep")
    }

    func testResponseFileURLSanitizesNameAndInfersExtension() throws {
        let entries = try HARImporter.parse(Data(fixture.utf8))
        let jsonURL = HARImporter.responseFileURL(for: entries[0], in: temporary)
        XCTAssertTrue(jsonURL.lastPathComponent.hasSuffix(".json"), jsonURL.lastPathComponent)
        XCTAssertTrue(jsonURL.lastPathComponent.contains("users"))

        let pngURL = HARImporter.responseFileURL(for: entries[1], in: temporary)
        XCTAssertTrue(pngURL.lastPathComponent.hasSuffix(".png"), pngURL.lastPathComponent)
        XCTAssertTrue(pngURL.lastPathComponent.contains("logo"))

        var entry = HAREntry(request: HARRequest(method: "GET", url: nil, headers: nil), response: nil)
        let fallback = HARImporter.responseFileURL(for: entry, in: temporary)
        XCTAssertTrue(fallback.lastPathComponent.hasSuffix(".bin"), fallback.lastPathComponent)
        XCTAssertTrue(fallback.lastPathComponent.contains("response"), fallback.lastPathComponent)
        entry = HAREntry(request: HARRequest(method: "GET", url: "notaurl", headers: nil), response: nil)
        let noPath = HARImporter.responseFileURL(for: entry, in: temporary)
        XCTAssertTrue(noPath.lastPathComponent.contains("notaurl"), noPath.lastPathComponent)
    }

    func testFileExtensionHandlesParameterizedMimeTypes() {
        XCTAssertEqual(HARImporter.fileExtension(forMimeType: "application/json; charset=utf-8"), "json")
        XCTAssertEqual(HARImporter.fileExtension(forMimeType: "text/CSV".lowercased()), "bin")
        XCTAssertEqual(HARImporter.fileExtension(forMimeType: nil), "bin")
    }
}
