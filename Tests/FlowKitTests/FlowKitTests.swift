import XCTest
import SwiftBrotli
@testable import FlowKit

final class HTTPMessageParserTests: XCTestCase {
    private func data(_ text: String) -> Data { Data(text.utf8) }

    func testParsesStatusLineVersionAndCode() {
        let parsed = HTTPMessageParser.parseStatusLine("HTTP/1.1 200 OK")
        XCTAssertEqual(parsed?.version, "HTTP/1.1")
        XCTAssertEqual(parsed?.code, 200)

        let withoutReason = HTTPMessageParser.parseStatusLine("HTTP/1.0 404")
        XCTAssertEqual(withoutReason?.version, "HTTP/1.0")
        XCTAssertEqual(withoutReason?.code, 404)
    }

    func testRejectsMalformedStatusLines() {
        XCTAssertNil(HTTPMessageParser.parseStatusLine("200 OK"))
        XCTAssertNil(HTTPMessageParser.parseStatusLine("HTTP/1.1"))
        XCTAssertNil(HTTPMessageParser.parseStatusLine("HTTP/1.1 abc"))
        XCTAssertNil(HTTPMessageParser.parseStatusLine("HTTP/1.1 999"), "a code outside 100...599 is not a status")
        XCTAssertNil(HTTPMessageParser.parseStatusLine("HTTP/1.1 99"))
    }

    func testParsesAFullResponseWithCRLF() {
        let message = data("HTTP/1.1 404 Not Found\r\nContent-Type: text/plain\r\nX-Mapped: yes\r\n\r\nnope")
        let response = HTTPMessageParser.response(from: message)
        XCTAssertEqual(response?.statusCode, 404)
        XCTAssertEqual(response?.httpVersion, "HTTP/1.1")
        XCTAssertEqual(response?.headers["Content-Type"], "text/plain")
        XCTAssertEqual(response?.headers["X-Mapped"], "yes")
        XCTAssertEqual(response?.body, data("nope"))
    }

    func testParsesAFullResponseWithBareLF() {
        let message = data("HTTP/1.1 200 OK\nContent-Type: application/json\n\n{\"a\":1}")
        let response = HTTPMessageParser.response(from: message)
        XCTAssertEqual(response?.statusCode, 200)
        XCTAssertEqual(response?.headers["Content-Type"], "application/json")
        XCTAssertEqual(response?.body, data("{\"a\":1}"))
    }

    func testMessageWithoutABodyStillParses() {
        let message = data("HTTP/1.1 204 No Content\r\n\r\n")
        let response = HTTPMessageParser.response(from: message)
        XCTAssertEqual(response?.statusCode, 204)
        XCTAssertEqual(response?.body, Data())
    }

    func testHeaderWithoutAColonIsRejected() {
        XCTAssertNil(HTTPMessageParser.response(from: data("HTTP/1.1 200 OK\r\nBrokenHeader\r\n\r\n")))
    }

    func testHeaderWithAnEmptyNameIsRejected() {
        XCTAssertNil(HTTPMessageParser.response(from: data("HTTP/1.1 200 OK\r\n: value\r\n\r\n")))
    }

    func testNonMessageDataIsNotParsed() {
        XCTAssertNil(HTTPMessageParser.response(from: data("{\"just\":\"json\"}")))
    }

    func testSplitHeadAndBodyPrefersCRLFCRLF() {
        let split = HTTPMessageParser.splitHeadAndBody(data("head\r\n\r\nbody"))
        XCTAssertEqual(split.head, data("head"))
        XCTAssertEqual(split.body, data("body"))
    }

    func testSplitHeadAndBodyFallsBackToLFLF() {
        let split = HTTPMessageParser.splitHeadAndBody(data("head\n\nbody"))
        XCTAssertEqual(split.head, data("head"))
        XCTAssertEqual(split.body, data("body"))
    }

    func testSplitHeadAndBodyWithoutASeparatorTreatsEverythingAsHead() {
        let split = HTTPMessageParser.splitHeadAndBody(data("no separator here"))
        XCTAssertEqual(split.head, data("no separator here"))
        XCTAssertEqual(split.body, Data())
    }
}

final class BodyFormattingTests: XCTestCase {
    func testTextDecodesUTF8ByDefault() {
        XCTAssertEqual(BodyFormatting.text(from: Data("hello".utf8)), "hello")
    }

    func testTextHonoursTheDeclaredCharset() {
        let contentType = MIMEType(rawValue: "text/plain; charset=utf-8")
        XCTAssertEqual(BodyFormatting.text(from: Data("héllo".utf8), contentType: contentType), "héllo")
    }

    func testTextFallsBackToLatin1ForArbitraryBytes() {
        // 0xFF is not valid UTF-8, so the Latin-1 fallback must still produce a string.
        let decoded = BodyFormatting.text(from: Data([0xFF, 0xFE]))
        XCTAssertEqual(decoded?.count, 2)
    }

    func testTextOfEmptyDataIsAnEmptyString() {
        XCTAssertEqual(BodyFormatting.text(from: Data()), "")
    }

    func testPrettyJSONSortsAndIndentsKeys() {
        let pretty = BodyFormatting.prettyJSON(Data("{\"b\":1,\"a\":2}".utf8))
        let text = try? XCTUnwrap(pretty)
        XCTAssertNotNil(text)
        XCTAssertTrue(text?.contains("\n") == true, "pretty output should be multi-line")
        let a = text?.range(of: "\"a\"")
        let b = text?.range(of: "\"b\"")
        XCTAssertNotNil(a)
        XCTAssertNotNil(b)
        if let a, let b { XCTAssertTrue(a.lowerBound < b.lowerBound, "keys should be sorted") }
    }

    func testPrettyJSONIsNilForInvalidInput() {
        XCTAssertNil(BodyFormatting.prettyJSON(Data("not json".utf8)))
        XCTAssertNil(BodyFormatting.prettyJSON(Data()))
    }

    func testIsValidJSON() {
        XCTAssertTrue(BodyFormatting.isValidJSON(Data("[]".utf8)))
        XCTAssertTrue(BodyFormatting.isValidJSON(Data("\"fragment\"".utf8)), "fragments are allowed")
        XCTAssertFalse(BodyFormatting.isValidJSON(Data("nope".utf8)))
        XCTAssertFalse(BodyFormatting.isValidJSON(Data()))
    }

    func testFormPairsDecodePlusAndPercentEscapes() {
        let pairs = BodyFormatting.formPairs(Data("a=1&b=hello+world&c=%2F".utf8))
        XCTAssertEqual(pairs.map(\.name), ["a", "b", "c"])
        XCTAssertEqual(pairs.map(\.value), ["1", "hello world", "/"])
    }

    func testFormPairsHandlesAKeyWithoutAValue() {
        let pairs = BodyFormatting.formPairs(Data("flag".utf8))
        XCTAssertEqual(pairs.count, 1)
        XCTAssertEqual(pairs.first?.name, "flag")
        XCTAssertEqual(pairs.first?.value, "")
    }

    func testFormPairsOfEmptyDataIsEmpty() {
        XCTAssertTrue(BodyFormatting.formPairs(Data()).isEmpty)
    }

    func testHexDumpFormatsOffsetHexAndASCII() {
        let dump = BodyFormatting.hexDump(Data([0x41, 0x42, 0x00, 0x1F]))
        XCTAssertTrue(dump.hasPrefix("00000000"), dump)
        XCTAssertTrue(dump.contains("41 42 00 1f"), dump)
        XCTAssertTrue(dump.hasSuffix("AB.."), dump)
    }

    func testHexDumpWrapsAtBytesPerLine() {
        let dump = BodyFormatting.hexDump(Data(repeating: 0x41, count: 20), bytesPerLine: 16)
        let lines = dump.split(separator: "\n")
        XCTAssertEqual(lines.count, 2)
        XCTAssertTrue(lines[0].hasPrefix("00000000"), String(lines[0]))
        XCTAssertTrue(lines[1].hasPrefix("00000010"), String(lines[1]))
    }

    func testHexDumpOfEmptyDataIsEmpty() {
        XCTAssertEqual(BodyFormatting.hexDump(Data()), "")
    }

    func testHexDumpHandlesALargeBinaryBody() {
        // A compressed body is where the dump was rendering garbage bytes; it must
        // produce one line per row rather than fault.
        let dump = BodyFormatting.hexDump(Data(repeating: 0xFF, count: 4096))
        XCTAssertEqual(dump.split(separator: "\n").count, 256)
        XCTAssertTrue(dump.hasPrefix("00000000  ff ff"), dump)
    }

    func testByteCountIsHumanReadable() {
        XCTAssertFalse(BodyFormatting.byteCount(0).isEmpty)
        XCTAssertTrue(BodyFormatting.byteCount(1536).contains("KB"), BodyFormatting.byteCount(1536))
    }
}

final class MIMETypeTests: XCTestCase {
    func testParsesTypeSubtypeAndParameters() {
        let type = MIMEType(rawValue: "application/json; charset=utf-8")
        XCTAssertEqual(type?.essence, "application/json")
        XCTAssertEqual(type?.charset, "utf-8")
        XCTAssertTrue(type?.isJSON == true)
    }

    func testRejectsValuesWithoutASlash() {
        XCTAssertNil(MIMEType(rawValue: "application"))
        XCTAssertNil(MIMEType(rawValue: ""))
    }

    func testInferredContentTypes() {
        XCTAssertEqual(MIMEType.inferred(forPathExtension: "json").essence, "application/json")
        XCTAssertEqual(MIMEType.inferred(forPathExtension: "JSON").essence, "application/json")
        XCTAssertEqual(MIMEType.inferred(forPathExtension: "html").essence, "text/html")
        XCTAssertEqual(MIMEType.inferred(forPathExtension: "svg").essence, "image/svg+xml")
        XCTAssertEqual(
            MIMEType.inferred(forPathExtension: "unknown").essence,
            "application/octet-stream",
            "an unidentified extension is served as raw bytes"
        )
        XCTAssertTrue(MIMEType.inferred(forPathExtension: "png").isImage)
    }
}

final class ContentDecodingTests: XCTestCase {
    /// `{"detail":"Data autentikasi tidak diberikan."}`, the plaintext behind each vector.
    private let plain = Data(#"{"detail":"Data autentikasi tidak diberikan."}"#.utf8)

    private func base64(_ value: String) -> Data {
        Data(base64Encoded: value)!
    }

    private let gzipBody = "H4sIANhW0moC/6tWSkktSczMUbJSckksSVRILC1JzSvJzE4szlQoyUxJzFZIyUxKLQIK5Okp1QIAE4yl7y4AAAA="
    private let zlibBody = "eNqrVkpJLUnMzFGyUnJJLElUSCwtSc0rycxOLM5UKMlMScxWSMlMSi0CCuTpKdUCAIB4EI4="
    private let rawDeflateBody = "q1ZKSS1JzMxRslJySSxJVEgsLUnNK8nMTizOVCjJTEnMVkjJTEotAgrk6SnVAgA="
    private let brotliBody = "Gy0AAETdluoZ/XSzqUxuGAeD3iRmJQJJVF3qoQIINHQWjRd4K3lkpWBaaMyt5HJ8"
    private let zstdBody = "KLUv/QRocQEAeyJkZXRhaWwiOiJEYXRhIGF1dGVudGlrYXNpIHRpZGFrIGRpYmVyaWthbi4iffnBl0E="

    func testDecodesGzip() {
        XCTAssertEqual(ContentDecoding.decode(base64(gzipBody), encoding: "gzip"), plain)
    }

    func testDecodesGzipIgnoringCaseAndParameters() {
        XCTAssertEqual(ContentDecoding.decode(base64(gzipBody), encoding: "GZip"), plain)
        XCTAssertEqual(ContentDecoding.decode(base64(gzipBody), encoding: "gzip, br"), plain)
    }

    func testDecodesZlibWrappedDeflate() {
        XCTAssertEqual(ContentDecoding.decode(base64(zlibBody), encoding: "deflate"), plain)
    }

    func testDecodesRawDeflateWithoutAWrapper() {
        XCTAssertEqual(ContentDecoding.decode(base64(rawDeflateBody), encoding: "deflate"), plain)
    }

    func testDecodesBrotli() {
        XCTAssertEqual(ContentDecoding.decode(base64(brotliBody), encoding: "br"), plain)
    }

    func testDecodesZstandard() {
        XCTAssertEqual(ContentDecoding.decode(base64(zstdBody), encoding: "zstd"), plain)
    }

    func testDecodesBrotliPayloadLargerThanTheFirstBuffer() {
        // The decoder is one-shot and reports a too-small buffer the same way it reports
        // corrupt input, so this exercises the growth ladder past a single attempt.
        let large = Data(String(repeating: "the quick brown fox jumps over the lazy dog. ", count: 7000).utf8)
        guard let compressed = brotliCompress(large) else {
            XCTFail("fixture did not compress")
            return
        }
        XCTAssertLessThan(compressed.count, large.count, "the fixture should actually be compressed")
        XCTAssertEqual(ContentDecoding.decode(compressed, encoding: "br"), large)
    }

    private func brotliCompress(_ data: Data) -> Data? {
        if case .success(let encoded) = Brotli().compress(data) { return encoded }
        return nil
    }

    func testLeavesUnsupportedAndAbsentEncodingsToTheCaller() {
        XCTAssertNil(ContentDecoding.decode(base64(gzipBody), encoding: nil))
        XCTAssertNil(ContentDecoding.decode(plain, encoding: "identity"))
        XCTAssertNil(ContentDecoding.decode(plain, encoding: "compress"))
        XCTAssertNil(ContentDecoding.decode(plain, encoding: "made-up-coding"))
    }

    func testRejectsACorruptGzipStream() {
        XCTAssertNil(ContentDecoding.decode(Data([0x1f, 0x8b, 0x08, 0x00]), encoding: "gzip"))
        XCTAssertNil(ContentDecoding.decode(Data("not gzip at all".utf8), encoding: "gzip"))
    }

    func testRejectsCorruptBrotliAndZstandardStreams() {
        XCTAssertNil(ContentDecoding.decode(Data("not brotli".utf8), encoding: "br"))
        XCTAssertNil(ContentDecoding.decode(Data("not zstd".utf8), encoding: "zstd"))
    }

    func testResponseDecodedBodyReversesTheHeaderEncoding() {
        var headers = HTTPHeaders()
        headers["Content-Encoding"] = "gzip"
        let response = HTTPResponse(statusCode: 200, headers: headers, body: base64(gzipBody))
        XCTAssertEqual(response.decodedBody, plain)
    }

    func testResponseDecodedBodyReversesBrotliAndZstandard() {
        for (coding, body) in [("br", brotliBody), ("zstd", zstdBody)] {
            var headers = HTTPHeaders()
            headers["Content-Encoding"] = coding
            let response = HTTPResponse(statusCode: 200, headers: headers, body: base64(body))
            XCTAssertEqual(response.decodedBody, plain, coding)
        }
    }

    func testResponseDecodedBodyIsRawWhenUncompressed() {
        let response = HTTPResponse(statusCode: 200, body: plain)
        XCTAssertEqual(response.decodedBody, plain)
    }
}