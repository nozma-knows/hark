import Foundation
@testable import Hark
import XCTest

final class HistoryStoreTests: XCTestCase {
    private var tempDir: URL!
    private var fileURL: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "hark-history-tests-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
        fileURL = tempDir.appending(path: "history.jsonl")
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - record / load

    @MainActor
    func test_record_persistsAndReads() {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "hello world", kind: .dictate))
        XCTAssertEqual(store.entries.count, 1)
        XCTAssertEqual(store.entries[0].transcript, "hello world")

        // A second store reading the same file sees the persisted entry.
        let other = HistoryStore(url: fileURL)
        other.load()
        XCTAssertEqual(other.entries.count, 1)
    }

    @MainActor
    func test_record_keepsNewestFirst() {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "first", kind: .dictate))
        store.record(makeEntry(transcript: "second", kind: .dictate))
        store.record(makeEntry(transcript: "third", kind: .dictate))
        XCTAssertEqual(store.entries.map(\.transcript), ["third", "second", "first"])
    }

    @MainActor
    func test_record_enforcesMaxEntries() {
        let store = HistoryStore(url: fileURL)
        for index in 0..<(HistoryStore.maxEntries + 50) {
            store.record(makeEntry(transcript: "entry \(index)", kind: .dictate))
        }
        XCTAssertEqual(store.entries.count, HistoryStore.maxEntries)
        // Newest entry is still present.
        XCTAssertEqual(store.entries.first?.transcript, "entry \(HistoryStore.maxEntries + 49)")
    }

    // MARK: - search

    @MainActor
    func test_search_caseInsensitiveSubstringMatch() {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "Open Linear ticket", kind: .command))
        store.record(makeEntry(transcript: "Take a screenshot", kind: .command))
        store.record(makeEntry(transcript: "Schedule retro prep", kind: .command))

        XCTAssertEqual(store.search("linear").count, 1)
        XCTAssertEqual(store.search("LINEAR").count, 1)
        XCTAssertEqual(store.search("retro").count, 1)
        XCTAssertEqual(store.search("").count, 3)
        XCTAssertEqual(store.search("   ").count, 3, "whitespace-only query returns all entries")
    }

    @MainActor
    func test_search_matchesPolishedAndSummary() {
        let store = HistoryStore(url: fileURL)
        store.record(
            HistoryEntry(
                id: UUID(),
                timestamp: Date(),
                kind: .dictate,
                transcript: "raw text here",
                polished: "Polished sentence about migration.",
                summary: "Polished sentence about migration.",
                succeeded: true
            )
        )
        XCTAssertEqual(store.search("migration").count, 1)
        XCTAssertEqual(store.search("Polished").count, 1)
    }

    // MARK: - clear

    @MainActor
    func test_clear_removesEntriesAndFile() {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "x", kind: .dictate))
        XCTAssertTrue(FileManager.default.fileExists(atPath: fileURL.path))
        store.clear()
        XCTAssertTrue(store.entries.isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path))
    }

    // MARK: - persistence shape

    @MainActor
    func test_persistedFile_isJsonLines() throws {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "alpha", kind: .dictate))
        store.record(makeEntry(transcript: "beta", kind: .command))

        let text = try String(contentsOf: fileURL, encoding: .utf8)
        let lines = text.split(whereSeparator: \.isNewline)
        XCTAssertEqual(lines.count, 2)
        // Each line is a complete JSON object.
        for line in lines {
            let data = Data(line.utf8)
            XCTAssertNoThrow(try JSONSerialization.jsonObject(with: data))
        }
    }

    @MainActor
    func test_corruptedLines_areSkipped() throws {
        let store = HistoryStore(url: fileURL)
        store.record(makeEntry(transcript: "good", kind: .dictate))

        // Manually append a malformed line, then a valid one again.
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var data = try Data(contentsOf: fileURL)
        data.append(Data("not-json\n".utf8))
        let appendEntry = makeEntry(transcript: "also good", kind: .dictate)
        try data.append(encoder.encode(appendEntry))
        data.append(0x0A)
        try data.write(to: fileURL)

        let reloaded = HistoryStore(url: fileURL)
        reloaded.load()
        XCTAssertEqual(reloaded.entries.count, 2)
    }

    // MARK: - HistoryEntry helpers

    func test_displayText_prefersPolishedWhenSet() {
        let entry = HistoryEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .dictate,
            transcript: "raw",
            polished: "polished",
            summary: "polished",
            succeeded: true
        )
        XCTAssertEqual(entry.displayText, "polished")
    }

    func test_displayText_fallsBackToTranscriptForCommand() {
        let entry = HistoryEntry(
            id: UUID(),
            timestamp: Date(),
            kind: .command,
            transcript: "open Linear",
            polished: nil,
            summary: "Opened Linear",
            succeeded: true
        )
        XCTAssertEqual(entry.displayText, "open Linear")
    }

    // MARK: - Helpers

    private func makeEntry(transcript: String, kind: HistoryEntry.Kind) -> HistoryEntry {
        HistoryEntry(
            id: UUID(),
            timestamp: Date(),
            kind: kind,
            transcript: transcript,
            polished: kind == .command ? nil : "Polished: \(transcript)",
            summary: kind == .command ? "Ran" : transcript,
            succeeded: true
        )
    }
}
