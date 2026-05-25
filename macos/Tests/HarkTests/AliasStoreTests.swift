import Foundation
@testable import Hark
import XCTest

final class AliasStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "hark-alias-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appending(path: "aliases.json")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Add

    @MainActor
    func test_add_persistsAndReturnsAlias() {
        let store = AliasStore(url: fileURL)
        let alias = store.add(phrase: "Standup", commands: ["open -a Zoom", "open -a Slack"])
        XCTAssertNotNil(alias)
        XCTAssertEqual(store.aliases.count, 1)
        XCTAssertEqual(store.aliases[0].phrase, "standup", "phrase should be lowercased")
        XCTAssertEqual(store.aliases[0].commands, ["open -a Zoom", "open -a Slack"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
    }

    @MainActor
    func test_add_rejectsEmptyPhrase() {
        let store = AliasStore(url: fileURL)
        XCTAssertNil(store.add(phrase: "  ", commands: ["echo hi"]))
        XCTAssertTrue(store.aliases.isEmpty)
    }

    @MainActor
    func test_add_rejectsZeroCommands() {
        let store = AliasStore(url: fileURL)
        XCTAssertNil(store.add(phrase: "x", commands: []))
        XCTAssertNil(store.add(phrase: "x", commands: ["   "]))
        XCTAssertTrue(store.aliases.isEmpty)
    }

    @MainActor
    func test_add_filtersWhitespaceCommands() {
        let store = AliasStore(url: fileURL)
        let alias = store.add(phrase: "x", commands: ["echo a", "   ", "echo b"])
        XCTAssertEqual(alias?.commands, ["echo a", "echo b"])
    }

    // MARK: - Update + delete

    @MainActor
    func test_update_replacesExisting() {
        let store = AliasStore(url: fileURL)
        guard let original = store.add(phrase: "x", commands: ["echo a"]) else {
            XCTFail("add failed")
            return
        }
        XCTAssertTrue(store.update(Alias(id: original.id, phrase: "y", commands: ["echo b"])))
        XCTAssertEqual(store.aliases[0].phrase, "y")
        XCTAssertEqual(store.aliases[0].commands, ["echo b"])
    }

    @MainActor
    func test_update_returnsFalseForUnknownId() {
        let store = AliasStore(url: fileURL)
        XCTAssertFalse(store.update(Alias(id: UUID(), phrase: "x", commands: ["echo a"])))
    }

    @MainActor
    func test_update_rejectsInvalidContent() {
        let store = AliasStore(url: fileURL)
        guard let alias = store.add(phrase: "x", commands: ["echo a"]) else {
            XCTFail("add failed")
            return
        }
        XCTAssertFalse(store.update(Alias(id: alias.id, phrase: "", commands: ["echo b"])))
        XCTAssertFalse(store.update(Alias(id: alias.id, phrase: "y", commands: [])))
    }

    @MainActor
    func test_delete_removesById() {
        let store = AliasStore(url: fileURL)
        guard let alias = store.add(phrase: "x", commands: ["echo a"]) else {
            XCTFail("add failed")
            return
        }
        store.delete(id: alias.id)
        XCTAssertTrue(store.aliases.isEmpty)
    }

    @MainActor
    func test_delete_unknownIdIsNoOp() {
        let store = AliasStore(url: fileURL)
        store.add(phrase: "x", commands: ["echo a"])
        store.delete(id: UUID())
        XCTAssertEqual(store.aliases.count, 1)
    }

    // MARK: - Persistence

    @MainActor
    func test_reload_picksUpFileEdits() throws {
        let store = AliasStore(url: fileURL)
        store.add(phrase: "x", commands: ["echo a"])
        XCTAssertEqual(store.aliases.count, 1)

        // Simulate a second instance writing the file (e.g. the sidecar
        // tools, or a manual edit from outside).
        let payload: [String: Any] = [
            "version": 1,
            "aliases": [
                ["id": UUID().uuidString, "phrase": "y", "commands": ["echo b"]],
                ["id": UUID().uuidString, "phrase": "z", "commands": ["echo c"]]
            ]
        ]
        let data = try JSONSerialization.data(withJSONObject: payload, options: [.prettyPrinted])
        try data.write(to: fileURL)

        store.reload()
        XCTAssertEqual(store.aliases.count, 2)
        XCTAssertEqual(store.aliases.map(\.phrase).sorted(), ["y", "z"])
    }

    @MainActor
    func test_aliases_areSortedByPhrase() {
        let store = AliasStore(url: fileURL)
        store.add(phrase: "zulu", commands: ["echo"])
        store.add(phrase: "alpha", commands: ["echo"])
        store.add(phrase: "mike", commands: ["echo"])
        XCTAssertEqual(store.aliases.map(\.phrase), ["alpha", "mike", "zulu"])
    }

    @MainActor
    func test_corruptedFile_yieldsEmptyAliasesNotCrash() throws {
        try "garbage".write(to: fileURL, atomically: true, encoding: .utf8)
        let store = AliasStore(url: fileURL)
        XCTAssertTrue(store.aliases.isEmpty)
    }

    @MainActor
    func test_writtenFile_matchesSidecarSchema() throws {
        let store = AliasStore(url: fileURL)
        store.add(phrase: "x", commands: ["echo a"])

        let data = try Data(contentsOf: fileURL)
        let json = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(json?["version"] as? Int, 1)
        let aliases = json?["aliases"] as? [[String: Any]]
        XCTAssertEqual(aliases?.count, 1)
        XCTAssertEqual(aliases?.first?["phrase"] as? String, "x")
        XCTAssertEqual(aliases?.first?["commands"] as? [String], ["echo a"])
        XCTAssertNotNil(aliases?.first?["id"] as? String)
    }

    // MARK: - Alias.make

    func test_aliasMake_lowercasesAndTrimsPhrase() {
        let alias = Alias.make(id: UUID(), phrase: "  Standup  ", commands: ["echo hi"])
        XCTAssertEqual(alias?.phrase, "standup")
    }

    func test_aliasMake_rejectsEmptyPhrase() {
        XCTAssertNil(Alias.make(id: UUID(), phrase: "   ", commands: ["echo hi"]))
    }
}
