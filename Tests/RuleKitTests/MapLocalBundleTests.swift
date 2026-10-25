import XCTest
import Foundation
import FlowKit
import ZIPFoundation
@testable import RuleKit

final class MapLocalBundleTests: XCTestCase {
    private let bundleID = UUID(uuidString: "11111111-1111-1111-1111-111111111111")!
    private let firstID = UUID(uuidString: "22222222-2222-2222-2222-222222222222")!
    private let secondID = UUID(uuidString: "33333333-3333-3333-3333-333333333333")!
    private var temporary: URL!

    override func setUpWithError() throws {
        temporary = FileManager.default.temporaryDirectory.appendingPathComponent("BundleTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: temporary, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: temporary)
    }

    func testPortableSameBasenameFilesPreserveResponseAndMatchingSchema() throws {
        let first = try put("one/response.http", Data("HTTP/1.1 201 Created\r\nContent-Type: application/json\r\nX-Fixture: first\r\nContent-Length: 11\r\n\r\n{\"first\":1}".utf8))
        let second = try put("two/response.http", Data("second body".utf8))
        let rules = [
            MapLocalRule(id: firstID, name: "Create", method: MethodMatch("POST"), url: "api.example.test/create", matchStyle: .exact,
                         includePath: true, destination: .file(first.path), responseDelay: 0.25),
            MapLocalRule(id: secondID, name: "Read", method: MethodMatch("GET"), url: "api.example.test/(.*)", matchStyle: .regex,
                         includePath: false, destination: .file(second.path), responseDelay: 2)
        ]
        let zip = temporary.appendingPathComponent("portable.zip")
        try MapLocalBundleArchive.exportBundle(rules: rules, name: "Portable", id: bundleID, to: zip)
        let inspected = try MapLocalBundleArchive.inspect(zip)
        XCTAssertNotEqual(inspected.overrides[0].destination.path, inspected.overrides[1].destination.path)
        XCTAssertEqual(inspected.overrides[0].destination.path, "map-local/\(firstID.uuidString)/response.http")
        let manifest = try archiveData(zip, path: "manifest.json")
        XCTAssertFalse(String(decoding: manifest, as: UTF8.self).contains(temporary.path))
        XCTAssertEqual(try archiveData(zip, path: inspected.overrides[0].destination.path), try Data(contentsOf: first))
        try FileManager.default.removeItem(at: first.deletingLastPathComponent())
        try FileManager.default.removeItem(at: second.deletingLastPathComponent())
        var file = RuleFile(isMapLocalEnabled: false)
        let rulesURL = temporary.appendingPathComponent("rules.json")
        let storage = temporary.appendingPathComponent("managed")
        let bundle = try MapLocalBundleArchive.importBundle(from: zip, into: &file, storageDirectory: storage, persistTo: rulesURL)
        XCTAssertEqual(bundle.ruleIDs, [firstID, secondID])
        XCTAssertFalse(file.isMapLocalEnabled)
        XCTAssertTrue(file.mapLocalRules.allSatisfy { !$0.isEnabled })
        XCTAssertEqual(RuleFile.load(from: rulesURL), file)
        for (original, imported) in Swift.zip(rules, file.mapLocalRules) {
            var expected = original
            expected.isEnabled = false
            expected.destination = imported.destination
            XCTAssertEqual(imported, expected)
        }
        try MapLocalBundleState.activate(id: bundle.id, in: &file)
        let response = try served(file.mapLocalRules, method: "POST", path: "/create")
        XCTAssertEqual(response.statusCode, 201)
        XCTAssertEqual(response.headers["X-Fixture"], "first")
        XCTAssertEqual(response.body, Data("{\"first\":1}".utf8))
    }

    func testDirectoryExportIncludesNestedIndexesEmptyFoldersAndLiteralPointers() throws {
        let root = temporary.appendingPathComponent("site")
        _ = try put("site/index.html", Data("home".utf8))
        _ = try put("site/nested/index.html", Data("nested home".utf8))
        _ = try put("site/assets/response.http", Data("HTTP/1.1 202 Accepted\r\nX-Fixture: directory\r\n\r\naccepted".utf8))
        let literalPointer = Data("<FILE_URL=\"/a/nonportable/path\">".utf8)
        _ = try put("site/pointer.txt", literalPointer)
        try FileManager.default.createDirectory(at: root.appendingPathComponent("empty"), withIntermediateDirectories: true)
        let rule = MapLocalRule(id: firstID, url: "api.example.test/*", destination: .directory(root.path))
        let zip = temporary.appendingPathComponent("directory.zip")
        try MapLocalBundleArchive.exportBundle(rules: [rule], name: "Directory", id: bundleID, to: zip)
        try FileManager.default.removeItem(at: root)
        var file = RuleFile()
        let imported = try MapLocalBundleArchive.importBundle(from: zip, into: &file, storageDirectory: temporary.appendingPathComponent("managed"), activate: true)
        XCTAssertTrue(MapLocalBundleState.isActive(imported, in: file.mapLocalRules))
        XCTAssertEqual(try served(file.mapLocalRules, path: "/").body, Data("home".utf8))
        XCTAssertEqual(try served(file.mapLocalRules, path: "/nested/").body, Data("nested home".utf8))
        let response = try served(file.mapLocalRules, path: "/assets/response.http")
        XCTAssertEqual(response.statusCode, 202)
        XCTAssertEqual(response.headers["X-Fixture"], "directory")
        XCTAssertEqual(try served(file.mapLocalRules, path: "/pointer.txt").body, literalPointer)
        let managedRoot = URL(fileURLWithPath: file.mapLocalRules[0].destination.path)
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: managedRoot.appendingPathComponent("empty").path, isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    func testFilePointerExportMaterializesOnlyOneStepWithReferencedMIME() throws {
        let payload = try put("source/body.json", Data("<FILE_URL=\"/must/not/be/followed\">".utf8))
        let pointer = try put("source/pointer.txt", Data("<FILE_URL=\"\(payload.path)\">".utf8))
        let original = MapLocalRule(id: firstID, url: "api.example.test/*", destination: .file(pointer.path))
        let expected = try served([original])
        let zip = temporary.appendingPathComponent("pointer.zip")
        try MapLocalBundleArchive.exportBundle(rules: [original], name: "Pointer", id: bundleID, to: zip)
        try FileManager.default.removeItem(at: pointer.deletingLastPathComponent())
        var file = RuleFile()
        try MapLocalBundleArchive.importBundle(from: zip, into: &file, storageDirectory: temporary.appendingPathComponent("managed"), activate: true)
        XCTAssertEqual(try served(file.mapLocalRules), expected)
    }

    func testLiteralPointerLikeFileBodiesRoundTripWithoutInterpretation() throws {
        for (index, body) in ["<FILE_URL=not-a-pointer", "<FILE_URL=\"\">"].enumerated() {
            let source = try put("literal-\(index).txt", Data(body.utf8))
            let rule = MapLocalRule(id: firstID, url: "api.example.test/*", destination: .file(source.path))
            let expected = try served([rule])
            let archive = temporary.appendingPathComponent("literal-\(index).zip")
            try MapLocalBundleArchive.exportBundle(rules: [rule], name: "Literal", to: archive)
            var file = RuleFile()
            try MapLocalBundleArchive.importBundle(
                from: archive, into: &file, storageDirectory: temporary.appendingPathComponent("literal-\(index)"), activate: true
            )
            XCTAssertEqual(try served(file.mapLocalRules), expected)
        }
    }

    func testCurrentEditedMembersExportInGlobalOrderWithoutRemovedMembers() throws {
        let first = try put("source/first.txt", Data("first".utf8))
        let second = try put("source/second.txt", Data("second".utf8))
        let initial = [
            MapLocalRule(id: firstID, url: "api.example.test/first", matchStyle: .exact, destination: .file(first.path)),
            MapLocalRule(id: secondID, url: "api.example.test/second", matchStyle: .exact, destination: .file(second.path))
        ]
        let originalZIP = temporary.appendingPathComponent("original.zip")
        try MapLocalBundleArchive.exportBundle(rules: initial, name: "Edited", id: bundleID, to: originalZIP)
        var file = RuleFile()
        let bundle = try MapLocalBundleArchive.importBundle(from: originalZIP, into: &file, storageDirectory: temporary.appendingPathComponent("managed"))
        let replacement = try put("edited/fresh.json", Data("{\"edited\":true}".utf8))
        file.mapLocalRules[1].name = "Edited live name"
        file.mapLocalRules[1].method = MethodMatch("PATCH")
        file.mapLocalRules[1].url = "api.example.test/current"
        file.mapLocalRules[1].responseDelay = 0.75
        file.mapLocalRules[1].destination = .file(replacement.path)
        file.mapLocalRules.reverse()
        file.mapLocalRules.removeAll { $0.id == firstID }
        file.mapLocalBundles[0].ruleIDs.removeAll { $0 == firstID }
        let selected = MapLocalBundleState.rules(in: bundle, from: file)
        XCTAssertEqual(selected.map(\.id), [secondID])
        let editedZIP = temporary.appendingPathComponent("edited.zip")
        try MapLocalBundleArchive.exportBundle(rules: selected, name: bundle.name, id: bundle.id, to: editedZIP)
        let inspected = try MapLocalBundleArchive.inspect(editedZIP)
        XCTAssertEqual(inspected.overrides.map(\.id), [secondID])
        XCTAssertEqual(inspected.overrides[0].name, "Edited live name")
        XCTAssertEqual(inspected.overrides[0].method, MethodMatch("PATCH"))
        XCTAssertEqual(inspected.overrides[0].url, "api.example.test/current")
        XCTAssertEqual(inspected.overrides[0].responseDelay, 0.75)
        var recipient = RuleFile()
        try MapLocalBundleArchive.importBundle(from: editedZIP, into: &recipient, storageDirectory: temporary.appendingPathComponent("recipient"), activate: true)
        XCTAssertEqual(try served(recipient.mapLocalRules, method: "PATCH", path: "/current").body, Data("{\"edited\":true}".utf8))
    }

    func testActivationIsExclusiveAndDeactivationLeavesOutsidersAndGlobalSwitchAlone() throws {
        let bundle = MapLocalBundle(id: bundleID, name: "QA", ruleIDs: [firstID])
        var file = RuleFile(isMapLocalEnabled: false, mapLocalRules: [
            MapLocalRule(id: secondID, isEnabled: true), MapLocalRule(id: firstID, isEnabled: false)
        ], mapLocalBundles: [bundle])
        XCTAssertEqual(try MapLocalBundleState.activate(id: bundle.id, in: &file), 1)
        XCTAssertTrue(file.isMapLocalEnabled)
        XCTAssertEqual(file.mapLocalRules.map(\.isEnabled), [false, true])
        XCTAssertTrue(MapLocalBundleState.isActive(bundle, in: file.mapLocalRules))
        file.mapLocalRules[0].isEnabled = true
        XCTAssertFalse(MapLocalBundleState.isActive(bundle, in: file.mapLocalRules))
        XCTAssertEqual(try MapLocalBundleState.deactivate(id: bundle.id, in: &file), 1)
        XCTAssertEqual(file.mapLocalRules.map(\.isEnabled), [true, false])
        XCTAssertTrue(file.isMapLocalEnabled)
        XCTAssertFalse(MapLocalBundleState.isActive(MapLocalBundle(name: "Empty", ruleIDs: []), in: []))
        XCTAssertFalse(MapLocalBundleState.isActive(bundle, in: []))
        let before = file
        XCTAssertThrowsError(try MapLocalBundleState.activate(id: UUID(), in: &file))
        XCTAssertEqual(file, before)
    }

    func testActivatingAnEmptyOrDeletedCollectionKeepsTheExistingConfiguration() throws {
        for ids in [[], [firstID]] {
            let bundle = MapLocalBundle(id: bundleID, name: "Empty", ruleIDs: ids)
            var file = RuleFile(isMapLocalEnabled: false, mapLocalRules: [
                MapLocalRule(id: secondID, isEnabled: true, url: "unowned")
            ], mapLocalBundles: [bundle])
            let original = file
            XCTAssertThrowsError(try MapLocalBundleState.activate(id: bundle.id, in: &file))
            XCTAssertEqual(file, original)
        }
    }

    func testBundleSelectorsResolveUUIDNameAndUnambiguousSlug() throws {
        let first = MapLocalBundle(id: bundleID, name: "QA Users", ruleIDs: [])
        let second = MapLocalBundle(id: secondID, name: "QA_Users", ruleIDs: [])
        var file = RuleFile(mapLocalBundles: [first])
        XCTAssertEqual(try MapLocalBundleState.resolve(bundleID.uuidString.lowercased(), in: file), first)
        XCTAssertEqual(try MapLocalBundleState.resolve(" qa USERS ", in: file), first)
        XCTAssertEqual(try MapLocalBundleState.resolve("qa-users", in: file), first)
        file.mapLocalBundles.append(second)
        XCTAssertThrowsError(try MapLocalBundleState.resolve("qa-users", in: file))
        XCTAssertThrowsError(try MapLocalBundleState.resolve("missing", in: file))
    }

    func testImportIdentityAndNameCollisionsNeverMutateDiskOrRules() throws {
        let archive = try fixture()
        let existingRule = MapLocalRule(id: secondID, name: "Existing", url: "untouched")
        let collisionFiles = [
            RuleFile(mapLocalRules: [existingRule], mapLocalBundles: [MapLocalBundle(id: bundleID, name: "Other", ruleIDs: [])]),
            RuleFile(mapLocalRules: [existingRule], mapLocalBundles: [MapLocalBundle(name: " fixture ", ruleIDs: [])]),
            RuleFile(mapLocalRules: [MapLocalRule(id: firstID, url: "existing")]),
            RuleFile(mapLocalBundles: [MapLocalBundle(name: "Dangling owner", ruleIDs: [firstID])])
        ]
        for (index, original) in collisionFiles.enumerated() {
            var file = original
            let persisted = temporary.appendingPathComponent("collision-\(index)/rules.json")
            try original.write(to: persisted)
            let before = try Data(contentsOf: persisted)
            let storage = persisted.deletingLastPathComponent().appendingPathComponent("managed")
            XCTAssertThrowsError(try MapLocalBundleArchive.importBundle(from: archive, into: &file, storageDirectory: storage, activate: true, persistTo: persisted))
            XCTAssertEqual(file, original)
            XCTAssertEqual(try Data(contentsOf: persisted), before)
            XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path))
        }
    }

    func testPersistenceFailureRollsBackImportAndManagedDirectory() throws {
        let archive = try fixture()
        var file = RuleFile(isMapLocalEnabled: false, mapLocalRules: [MapLocalRule(id: secondID, isEnabled: true, url: "existing")])
        let original = file
        let blocker = try put("not-a-directory", Data("keep".utf8))
        let storage = temporary.appendingPathComponent("managed")
        XCTAssertThrowsError(try MapLocalBundleArchive.importBundle(from: archive, into: &file, storageDirectory: storage, activate: true,
                                                                  persistTo: blocker.appendingPathComponent("rules.json")))
        XCTAssertEqual(file, original)
        XCTAssertEqual(try Data(contentsOf: blocker), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: storage.path), [])
    }

    func testRemovalPersistsBeforeCleanupAndNeverDeletesUnownedData() throws {
        let archive = try fixture()
        let storage = temporary.appendingPathComponent("managed")
        let rulesURL = temporary.appendingPathComponent("rules.json")
        var file = RuleFile()
        let bundle = try MapLocalBundleArchive.importBundle(from: archive, into: &file, storageDirectory: storage, persistTo: rulesURL)
        let importedPath = file.mapLocalRules[0].destination.path
        let unrelated = try put("unowned.txt", Data("keep".utf8))
        file.mapLocalRules.append(MapLocalRule(id: secondID, url: "unowned", destination: .file(unrelated.path)))
        let blocker = try put("persist-blocker", Data("keep".utf8))
        let original = file
        XCTAssertThrowsError(try MapLocalBundleState.remove(id: bundle.id, from: &file, storageDirectory: storage,
                                                          persistTo: blocker.appendingPathComponent("rules.json")))
        XCTAssertEqual(file, original)
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedPath))
        try MapLocalBundleState.remove(id: bundle.id, from: &file, storageDirectory: storage, persistTo: rulesURL)
        XCTAssertEqual(file.mapLocalRules.map(\.id), [secondID])
        XCTAssertTrue(file.mapLocalBundles.isEmpty)
        XCTAssertEqual(RuleFile.load(from: rulesURL), file)
        XCTAssertFalse(FileManager.default.fileExists(atPath: importedPath))
        XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    }

    func testRemovalKeepsManagedResourcesReferencedByAnOrdinaryRule() throws {
        var file = RuleFile()
        let storage = temporary.appendingPathComponent("managed")
        let bundle = try MapLocalBundleArchive.importBundle(from: fixture(), into: &file, storageDirectory: storage)
        let importedPath = file.mapLocalRules[0].destination.path
        file.mapLocalRules.append(MapLocalRule(id: secondID, url: "ordinary", destination: .file(importedPath)))
        try MapLocalBundleState.remove(id: bundle.id, from: &file, storageDirectory: storage)
        XCTAssertEqual(file.mapLocalRules.map(\.id), [secondID])
        XCTAssertTrue(FileManager.default.fileExists(atPath: importedPath))
    }

    func testExportFailurePreservesExistingArchiveBytes() throws {
        let destination = try put("existing.zip", Data("existing authorized destination".utf8))
        let rule = MapLocalRule(id: firstID, url: "api.example.test/*", destination: .file(temporary.appendingPathComponent("missing").path))
        XCTAssertThrowsError(try MapLocalBundleArchive.exportBundle(rules: [rule], name: "Missing", to: destination))
        XCTAssertEqual(try Data(contentsOf: destination), Data("existing authorized destination".utf8))
        XCTAssertFalse(try FileManager.default.contentsOfDirectory(atPath: temporary.path).contains { $0.hasPrefix(".bundle-export-") })
    }

    func testUnsafeArchivePathsAndTypesAreRejectedBeforeStorageMutation() throws {
        let invalidEntries: [RawEntry] = [
            RawEntry("../escaped", body: "bad"), RawEntry("/absolute", body: "bad"),
            RawEntry("C:/drive", body: "bad"), RawEntry("map-local\\escape", body: "bad"),
            RawEntry("map-local/../escape", body: "bad"), RawEntry("map-local//empty", body: "bad"),
            RawEntry("map-local/./dot", body: "bad"), RawEntry("map-local/null\u{0}", body: "bad"),
            RawEntry("map-local/link", body: "/outside", mode: 0xa000),
            RawEntry("map-local/fifo", body: "", mode: 0x1000),
            RawEntry("map-local/socket", body: "", mode: 0xc000),
            RawEntry("map-local/response.txt", body: "bad", localName: "../../local-traversal.txt"),
            RawEntry("map-local/response.txt", body: "bad", localName: "../../outside/body.txt"),
            RawEntry("map-local/response.txt", body: "bad", localName: "map-local/../evil.txt")
        ]
        for (index, entry) in invalidEntries.enumerated() {
            let archive = try fixture(extra: [entry], filename: "unsafe-\(index).zip")
            try assertRejectedWithoutMutation(archive)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: temporary.deletingLastPathComponent().appendingPathComponent("escaped").path))
    }

    func testDuplicateCaseUnicodeAndFileParentCollisionsAreRejected() throws {
        let extras: [[RawEntry]] = [
            [RawEntry("map-local/response.txt", body: "duplicate")],
            [RawEntry("map-local/RESPONSE.txt", body: "case alias")],
            [RawEntry("map-local/caf\u{e9}.txt", body: "one"), RawEntry("map-local/cafe\u{301}.txt", body: "two")],
            [RawEntry("map-local/response.txt/child", body: "file parent")],
            [RawEntry("map-local/parent", body: "file"), RawEntry("map-local/parent/", body: "", mode: 0x4000)]
        ]
        for (index, entries) in extras.enumerated() {
            try assertRejectedWithoutMutation(fixture(extra: entries, filename: "collision-path-\(index).zip"))
        }
    }

    func testCorruptionEncryptedEntriesAndTruncatedDirectoryAreRejected() throws {
        try assertRejectedWithoutMutation(fixture(extra: [RawEntry("map-local/bad.txt", body: "corrupt", checksum: 0)], filename: "bad-crc.zip"))
        try assertRejectedWithoutMutation(fixture(extra: [RawEntry("map-local/encrypted.txt", body: "secret", flags: 1)], filename: "encrypted.zip"))
        let source = try fixture(filename: "truncated.zip")
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: UInt64(try Data(contentsOf: source).count - 7))
        try handle.close()
        try assertRejectedWithoutMutation(source)
        let wrongCount = try fixture(filename: "wrong-count.zip")
        var bytes = try Data(contentsOf: wrongCount)
        bytes.replaceSubrange((bytes.count - 14)..<(bytes.count - 10), with: [3, 0, 3, 0])
        try bytes.write(to: wrongCount)
        try assertRejectedWithoutMutation(wrongCount)
    }

    func testActualDeflateExpansionCannotExceedDeclaredSize() throws {
        let manifest = try JSONEncoder().encode(baseManifest())
        let payload = Data(repeating: 65, count: 64 * 1_024)
        let archive = try Archive(data: Data(), accessMode: .create)
        try archive.addEntry(with: "manifest.json", type: .file, uncompressedSize: Int64(manifest.count)) {
            position, count in manifest.subdata(in: Int(position)..<min(Int(position) + count, manifest.count))
        }
        try archive.addEntry(with: "map-local/response.txt", type: .file, uncompressedSize: Int64(payload.count), compressionMethod: .deflate) {
            position, count in payload.subdata(in: Int(position)..<min(Int(position) + count, payload.count))
        }
        var bytes = try XCTUnwrap(archive.data)
        let resourceLocal = 30 + "manifest.json".utf8.count + manifest.count
        let centralStart = try XCTUnwrap(bytes.range(of: Data([0x50, 0x4b, 0x01, 0x02]))).lowerBound
        let resourceCentral = centralStart + 46 + "manifest.json".utf8.count
        bytes.replaceSubrange((resourceLocal + 22)..<(resourceLocal + 26), with: [1, 0, 0, 0])
        bytes.replaceSubrange((resourceCentral + 24)..<(resourceCentral + 28), with: [1, 0, 0, 0])
        let url = try put("expansion.zip", bytes)
        try assertRejectedWithoutMutation(url)
    }

    func testZIP64AndSplitArchiveMarkersAreRejected() throws {
        var zip64 = rawZIP([])
        zip64.replaceSubrange(8..<12, with: [0xff, 0xff, 0xff, 0xff])
        try assertRejectedWithoutMutation(put("zip64.zip", zip64))
        var split = rawZIP([])
        split.replaceSubrange(4..<6, with: [1, 0])
        try assertRejectedWithoutMutation(put("split.zip", split))
    }

    func testManifestVersionSchemaRuleAndDestinationValidation() throws {
        var valid = baseManifest()
        let mutations: [(inout MapLocalBundleManifest) -> Void] = [
            { $0.formatVersion = 2 }, { $0.name = " \n\t" }, { $0.overrides.append($0.overrides[0]) },
            { $0.overrides[0].url = " \n" }, { $0.overrides[0].matchStyle = .regex; $0.overrides[0].url = "[" },
            { $0.overrides[0].method = MethodMatch("BAD METHOD") }, { $0.overrides[0].responseDelay = -1 },
            { $0.overrides[0].destination = .file("/absolute/response.txt") },
            { $0.overrides[0].destination = .file("map-local/missing.txt") },
            { $0.overrides[0].destination = .directory("map-local/response.txt") },
            { $0.overrides[0].destination = .file("map-local/RESPONSE.txt") },
            { $0.overrides[0].destination = .file("outside.txt") }
        ]
        for (index, mutation) in mutations.enumerated() {
            valid = baseManifest()
            mutation(&valid)
            try assertRejectedWithoutMutation(fixture(manifest: valid, filename: "bad-manifest-\(index).zip"))
        }
        let malformed = try put("malformed.zip", rawZIP([RawEntry("manifest.json", body: "{\"formatVersion\":1,\"name\":\"Missing UUID\"}"),
                                                        RawEntry("map-local/response.txt", body: "response")]))
        try assertRejectedWithoutMutation(malformed)
        let pointer = try put("external-pointer.zip", rawZIP([
            RawEntry("manifest.json", data: try JSONEncoder().encode(baseManifest())),
            RawEntry("map-local/response.txt", body: "\u{2003}<FILE_URL=\"/outside/secret.json\">")
        ]))
        try assertRejectedWithoutMutation(pointer)
    }

    func testSymlinkedManagedRootIsRejectedWithoutTouchingTarget() throws {
        let target = temporary.appendingPathComponent("unowned-storage")
        try FileManager.default.createDirectory(at: target, withIntermediateDirectories: true)
        let marker = try put("unowned-storage/keep.txt", Data("keep".utf8))
        let symlink = temporary.appendingPathComponent("managed-symlink")
        try FileManager.default.createSymbolicLink(at: symlink, withDestinationURL: target)
        var file = RuleFile()
        let original = file
        XCTAssertThrowsError(try MapLocalBundleArchive.importBundle(from: fixture(), into: &file, storageDirectory: symlink))
        XCTAssertEqual(file, original)
        XCTAssertEqual(try Data(contentsOf: marker), Data("keep".utf8))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: target.path), ["keep.txt"])
    }

    func testResourceBoundariesRejectBeforeDecompressionOrExportRead() throws {
        let huge = RawEntry("map-local/huge", body: "x", compression: 8,
                            declaredSize: UInt32(MapLocalBundleZIPStructure.maximumFileBytes + 1))
        try assertRejectedWithoutMutation(fixture(extra: [huge], filename: "huge.zip"))
        let total = [
            RawEntry("map-local/first-big", body: "x", compression: 8, declaredSize: UInt32(MapLocalBundleZIPStructure.maximumFileBytes)),
            RawEntry("map-local/second-big", body: "x", compression: 8, declaredSize: UInt32(MapLocalBundleZIPStructure.maximumFileBytes))
        ]
        try assertRejectedWithoutMutation(fixture(extra: total, filename: "total-bound.zip"))
        let largeManifest = RawEntry("manifest.json", body: "x", compression: 8,
                                    declaredSize: UInt32(MapLocalBundleZIPStructure.maximumManifestBytes + 1))
        let largeManifestZIP = try put("large-manifest.zip", rawZIP([largeManifest]))
        try assertRejectedWithoutMutation(largeManifestZIP)
        let tooMany = try put("too-many.zip", rawZIP([], declaredCount: 10_001))
        try assertRejectedWithoutMutation(tooMany)
        let oversizedPath = RawEntry("map-local/" + String(repeating: "x", count: 1_025), body: "x")
        try assertRejectedWithoutMutation(fixture(extra: [oversizedPath], filename: "long-path.zip"))
        let largeArchive = try put("large-archive.zip", Data())
        let archiveHandle = try FileHandle(forWritingTo: largeArchive)
        try archiveHandle.truncate(atOffset: MapLocalBundleZIPStructure.maximumArchiveBytes + 1)
        try archiveHandle.close()
        try assertRejectedWithoutMutation(largeArchive)
        let source = try put("sparse.bin", Data())
        let handle = try FileHandle(forWritingTo: source)
        try handle.truncate(atOffset: MapLocalBundleZIPStructure.maximumFileBytes + 1)
        try handle.close()
        let export = temporary.appendingPathComponent("oversized-export.zip")
        XCTAssertThrowsError(try MapLocalBundleArchive.exportBundle(rules: [MapLocalRule(url: "api.example.test/*", destination: .file(source.path))], name: "Too large", to: export))
        XCTAssertFalse(FileManager.default.fileExists(atPath: export.path))
        var nonfinite = MapLocalRule(url: "api.example.test/*", destination: .file(source.path), responseDelay: .infinity)
        XCTAssertThrowsError(try MapLocalBundleArchive.exportBundle(rules: [nonfinite], name: "Infinite", to: export))
        nonfinite.responseDelay = .nan
        XCTAssertThrowsError(try MapLocalBundleArchive.exportBundle(rules: [nonfinite], name: "NaN", to: export))
    }

    private func baseManifest() -> MapLocalBundleManifest {
        MapLocalBundleManifest(id: bundleID, name: "Fixture", overrides: [
            MapLocalRule(id: firstID, name: "Fixture response", url: "api.example.test/*", destination: .file("map-local/response.txt"))
        ])
    }

    private func fixture(manifest: MapLocalBundleManifest? = nil, extra: [RawEntry] = [], filename: String = "fixture.zip") throws -> URL {
        try put(filename, rawZIP([
            RawEntry("manifest.json", data: try JSONEncoder().encode(manifest ?? baseManifest())),
            RawEntry("map-local/response.txt", body: "fixture body")
        ] + extra))
    }

    private func assertRejectedWithoutMutation(_ archive: URL, file: StaticString = #filePath, line: UInt = #line) throws {
        var rules = RuleFile(mapLocalRules: [MapLocalRule(id: secondID, url: "untouched")])
        let original = rules
        let storage = temporary.appendingPathComponent("reject-managed")
        let persisted = try put("untouched-rules.json", Data("original disk bytes".utf8))
        XCTAssertThrowsError(try MapLocalBundleArchive.inspect(archive), file: file, line: line)
        XCTAssertThrowsError(try MapLocalBundleArchive.importBundle(from: archive, into: &rules, storageDirectory: storage, activate: true, persistTo: persisted), file: file, line: line)
        XCTAssertEqual(rules, original, file: file, line: line)
        XCTAssertEqual(try Data(contentsOf: persisted), Data("original disk bytes".utf8), file: file, line: line)
        XCTAssertFalse(FileManager.default.fileExists(atPath: storage.path), file: file, line: line)
    }

    private func served(_ rules: [MapLocalRule], method: String = "GET", path: String = "/") throws -> HTTPResponse {
        let request = HTTPRequest(method: method, scheme: "https", host: "api.example.test", port: 443, path: path)
        guard case .served(let resolution) = MapLocalResponder.resolve(request: request, rules: rules) else {
            XCTFail("Expected imported response for \(method) \(path)")
            throw CocoaError(.fileReadUnknown)
        }
        return resolution.response
    }

    private func archiveData(_ url: URL, path: String) throws -> Data {
        let archive = try Archive(url: url, accessMode: .read)
        let entry = try XCTUnwrap(archive[path])
        var data = Data()
        _ = try archive.extract(entry) { data.append($0) }
        return data
    }

    private func put(_ path: String, _ data: Data) throws -> URL {
        let url = temporary.appendingPathComponent(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return url
    }

    private struct RawEntry {
        var name: String
        var data: Data
        var mode: UInt32
        var localName: String?
        var checksum: UInt32?
        var flags: UInt16
        var compression: UInt16
        var declaredSize: UInt32?

        init(_ name: String, body: String, mode: UInt32 = 0x8000, localName: String? = nil, checksum: UInt32? = nil,
             flags: UInt16 = 0, compression: UInt16 = 0, declaredSize: UInt32? = nil) {
            self.init(name, data: Data(body.utf8), mode: mode, localName: localName, checksum: checksum,
                      flags: flags, compression: compression, declaredSize: declaredSize)
        }

        init(_ name: String, data: Data, mode: UInt32 = 0x8000, localName: String? = nil, checksum: UInt32? = nil,
             flags: UInt16 = 0, compression: UInt16 = 0, declaredSize: UInt32? = nil) {
            self.name = name
            self.data = data
            self.mode = mode
            self.localName = localName
            self.checksum = checksum
            self.flags = flags
            self.compression = compression
            self.declaredSize = declaredSize
        }
    }

    // Raw records make hostile ZIP metadata deterministic without depending on what a
    // ZIP writer elects to normalize or reject before the consumer sees it.
    private func rawZIP(_ entries: [RawEntry], declaredCount: UInt16? = nil) -> Data {
        var data = Data()
        var central = Data()
        for entry in entries {
            let offset = UInt32(data.count)
            let name = Data(entry.name.utf8)
            let localName = Data((entry.localName ?? entry.name).utf8)
            let checksum = entry.checksum ?? crc32(entry.data)
            let size = entry.declaredSize ?? UInt32(entry.data.count)
            data.le32(0x04034b50)
            data.le16(20); data.le16(entry.flags | 0x800); data.le16(entry.compression)
            data.le16(0); data.le16(0); data.le32(checksum)
            data.le32(UInt32(entry.data.count)); data.le32(size)
            data.le16(UInt16(localName.count)); data.le16(0)
            data.append(localName); data.append(entry.data)
            central.le32(0x02014b50)
            central.le16(0x0314); central.le16(20); central.le16(entry.flags | 0x800); central.le16(entry.compression)
            central.le16(0); central.le16(0); central.le32(checksum)
            central.le32(UInt32(entry.data.count)); central.le32(size)
            central.le16(UInt16(name.count)); central.le16(0); central.le16(0)
            central.le16(0); central.le16(0); central.le32((entry.mode | 0o644) << 16); central.le32(offset)
            central.append(name)
        }
        let offset = UInt32(data.count)
        data.append(central)
        data.le32(0x06054b50); data.le16(0); data.le16(0)
        data.le16(declaredCount ?? UInt16(entries.count)); data.le16(declaredCount ?? UInt16(entries.count))
        data.le32(UInt32(central.count)); data.le32(offset); data.le16(0)
        return data
    }

    private func crc32(_ data: Data) -> UInt32 {
        var crc: UInt32 = .max
        for byte in data {
            crc ^= UInt32(byte)
            for _ in 0..<8 { crc = (crc >> 1) ^ (crc & 1 == 1 ? 0xedb88320 : 0) }
        }
        return ~crc
    }
}

private extension Data {
    mutating func le16(_ value: UInt16) {
        append(UInt8(truncatingIfNeeded: value)); append(UInt8(truncatingIfNeeded: value >> 8))
    }

    mutating func le32(_ value: UInt32) {
        le16(UInt16(truncatingIfNeeded: value)); le16(UInt16(truncatingIfNeeded: value >> 16))
    }
}
