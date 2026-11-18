import XCTest
@testable import FlowKit

final class DecodedBodyCacheTests: XCTestCase {
    func testCacheReturnsNilForUncompressedData() {
        let cache = DecodedBodyCache(capacity: 10)
        let data = "Hello, world!".data(using: .utf8)!
        let flowID = UUID()

        let result = cache.decoded(
            data: data,
            encoding: nil,
            flowID: flowID,
            revision: 0,
            isRequest: false
        )
        XCTAssertNil(result)
    }

    func testCacheStoresAndRetrievesDecodedGzipData() {
        let cache = DecodedBodyCache(capacity: 10)
        let originalText = "Hello, compressed world!"
        let rawData = originalText.data(using: .utf8)!
        let flowID = UUID()

        let cached = cache.decoded(
            data: rawData,
            encoding: "gzip",
            flowID: flowID,
            revision: 0,
            isRequest: false
        )
        let cachedAgain = cache.decoded(
            data: rawData,
            encoding: "gzip",
            flowID: flowID,
            revision: 0,
            isRequest: false
        )
        XCTAssertEqual(cached, cachedAgain)
    }

    func testRevisionChangeMissesCache() {
        let cache = DecodedBodyCache(capacity: 10)
        let flowID = UUID()
        let data = "sample".data(using: .utf8)!

        _ = cache.decoded(
            data: data,
            encoding: "gzip",
            flowID: flowID,
            revision: 1,
            isRequest: false
        )

        let entryRev1 = cache.cachedEntry(flowID: flowID, isRequest: false, revision: 1, byteCount: data.count, encoding: "gzip")
        let entryRev2 = cache.cachedEntry(flowID: flowID, isRequest: false, revision: 2, byteCount: data.count, encoding: "gzip")

        XCTAssertNotNil(entryRev1 as Any?)
        XCTAssertNil(entryRev2 as Any?)
    }

    func testCapacityEviction() {
        let cache = DecodedBodyCache(capacity: 2)
        let data = "data".data(using: .utf8)!
        let id1 = UUID()
        let id2 = UUID()
        let id3 = UUID()

        _ = cache.decoded(data: data, encoding: "gzip", flowID: id1, revision: 0, isRequest: false)
        _ = cache.decoded(data: data, encoding: "gzip", flowID: id2, revision: 0, isRequest: false)
        _ = cache.decoded(data: data, encoding: "gzip", flowID: id3, revision: 0, isRequest: false)

        let entry1 = cache.cachedEntry(flowID: id1, isRequest: false, revision: 0, byteCount: data.count, encoding: "gzip")
        let entry3 = cache.cachedEntry(flowID: id3, isRequest: false, revision: 0, byteCount: data.count, encoding: "gzip")

        XCTAssertNil(entry1 as Any?)
        XCTAssertNotNil(entry3 as Any?)
    }

    func testClearRemovesAllEntries() {
        let cache = DecodedBodyCache(capacity: 10)
        let flowID = UUID()
        let data = "data".data(using: .utf8)!

        _ = cache.decoded(data: data, encoding: "gzip", flowID: flowID, revision: 0, isRequest: false)
        cache.clear()

        let entry = cache.cachedEntry(flowID: flowID, isRequest: false, revision: 0, byteCount: data.count, encoding: "gzip")
        XCTAssertNil(entry as Any?)
    }

    func testConcurrentAccessIsThreadSafe() {
        let cache = DecodedBodyCache(capacity: 100)
        let count = 500

        DispatchQueue.concurrentPerform(iterations: count) { index in
            let id = UUID()
            let data = "test_\(index)".data(using: .utf8)!
            _ = cache.decoded(data: data, encoding: "gzip", flowID: id, revision: index, isRequest: index % 2 == 0)
        }
    }
}
