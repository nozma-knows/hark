@testable import Hark
import XCTest

/// Validates the file-based log channel directly. Each test runs against
/// an isolated temp directory so they don't write to (or read from)
/// `~/Library/Logs/Hark/`, and `flushSynchronously()` makes write
/// assertions deterministic.
final class FileLoggerTests: XCTestCase {
    private var tempDir: URL!

    override func setUp() {
        super.setUp()
        tempDir = FileManager.default.temporaryDirectory
            .appending(path: "FileLoggerTests-\(UUID().uuidString)", directoryHint: .isDirectory)
    }

    override func tearDown() {
        try? FileManager.default.removeItem(at: tempDir)
        super.tearDown()
    }

    // MARK: - Directory creation

    func testInitCreatesDirectoryIfMissing() {
        XCTAssertFalse(FileManager.default.fileExists(atPath: tempDir.path))
        _ = FileLogger(directory: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    func testInitToleratesExistingDirectory() {
        try? FileManager.default.createDirectory(
            at: tempDir,
            withIntermediateDirectories: true
        )
        // Must not throw or fail.
        _ = FileLogger(directory: tempDir)
        XCTAssertTrue(FileManager.default.fileExists(atPath: tempDir.path))
    }

    // MARK: - Basic write

    func testSingleLogWritesLine() throws {
        let logger = FileLogger(directory: tempDir)
        logger.log(.info, category: "Test", "hello world")
        logger.flushSynchronously()

        let url = tempDir.appending(path: "hark.log")
        let body = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(body.contains("hello world"))
        XCTAssertTrue(body.contains("[INFO]"))
        XCTAssertTrue(body.contains("[Test]"))
    }

    func testLogLevelsAreDistinguishable() throws {
        let logger = FileLogger(directory: tempDir)
        logger.log(.info, category: "x", "info line")
        logger.log(.warning, category: "x", "warn line")
        logger.log(.error, category: "x", "error line")
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        XCTAssertTrue(body.contains("[INFO] [x] info line"))
        XCTAssertTrue(body.contains("[WARN] [x] warn line"))
        XCTAssertTrue(body.contains("[ERROR] [x] error line"))
    }

    func testTimestampIsoFormat() throws {
        let logger = FileLogger(directory: tempDir)
        logger.log(.info, category: "x", "x")
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        // ISO8601 with fractional seconds: 2026-05-23T12:34:56.789Z
        let pattern = #"\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d+Z"#
        XCTAssertNotNil(body.range(of: pattern, options: .regularExpression))
    }

    // MARK: - Ordering

    func testWritesPreserveOrderFromOneThread() throws {
        let logger = FileLogger(directory: tempDir)
        for i in 0..<50 {
            logger.log(.info, category: "x", "line-\(i)")
        }
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        let lines = body.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 50)
        for (i, line) in lines.enumerated() {
            XCTAssertTrue(line.hasSuffix("line-\(i)"), "out-of-order at index \(i): \(line)")
        }
    }

    func testConcurrentWritesDoNotInterleaveCharacters() async throws {
        // 8 threads, each writing 20 lines. We don't care about the
        // ordering between threads — but we DO care that no single line
        // is torn (interleaved bytes from another thread mid-write). The
        // serial queue is what guarantees this; the test would fail if
        // someone refactored away the queue.
        let logger = FileLogger(directory: tempDir)
        await withTaskGroup(of: Void.self) { group in
            for t in 0..<8 {
                group.addTask {
                    for i in 0..<20 {
                        logger.log(.info, category: "T\(t)", "msg-\(i)")
                    }
                }
            }
        }
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        let lines = body.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 8 * 20)
        // Every line must match the expected format. If bytes interleaved
        // we'd see lines like "2026...[INFO] [T2] msg-T5] msg-7".
        for line in lines {
            XCTAssertNotNil(
                line.range(of: #"\[T\d+\] msg-\d+$"#, options: .regularExpression),
                "torn line: \(line)"
            )
        }
    }

    // MARK: - Rotation

    func testRotationHappensAtThreshold() {
        // 200-byte rotation threshold; each line is ~50 bytes; after a few
        // writes the rotation moves hark.log → hark.log.1.
        let logger = FileLogger(directory: tempDir, maxFileSize: 200)
        for i in 0..<20 {
            logger.log(.info, category: "x", String(repeating: "a", count: 30) + "-\(i)")
        }
        logger.flushSynchronously()

        let current = tempDir.appending(path: "hark.log")
        let rotated = tempDir.appending(path: "hark.log.1")
        XCTAssertTrue(FileManager.default.fileExists(atPath: current.path))
        XCTAssertTrue(
            FileManager.default.fileExists(atPath: rotated.path),
            "rotated file must exist after writing past threshold"
        )

        // Current file should be smaller than threshold (post-rotation
        // it's fresh and accumulating). Rotated holds older content.
        let currentSize = (try? FileManager.default.attributesOfItem(atPath: current.path)[.size] as? Int) ?? 0
        XCTAssertLessThanOrEqual(currentSize, 200 * 3, "current should be small after rotation")
    }

    func testOnlyOneRotationGenerationKept() throws {
        // After enough writes to trigger multiple rotations, only ONE
        // rotated file should exist (hark.log.1) — older rotations get
        // overwritten, not accumulated.
        let logger = FileLogger(directory: tempDir, maxFileSize: 100)
        for i in 0..<100 {
            logger.log(.info, category: "x", "line-\(i)")
        }
        logger.flushSynchronously()

        let allFiles = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
        let logFiles = allFiles.filter { $0.hasPrefix("hark.log") }
        XCTAssertEqual(
            logFiles.sorted(),
            ["hark.log", "hark.log.1"],
            "exactly two log files should exist; got: \(logFiles.sorted())"
        )
    }

    // MARK: - currentLogs() reflection

    func testCurrentLogsReturnsExistingFilesOnly() {
        let logger = FileLogger(directory: tempDir)
        // Before any writes: directory exists, but log file doesn't yet
        // (createFile happens on first openHandle in the queue). After
        // flush, the file exists.
        logger.log(.info, category: "x", "ensure file")
        logger.flushSynchronously()

        let logs = logger.currentLogs()
        XCTAssertEqual(logs.count, 1)
        XCTAssertEqual(logs.first?.lastPathComponent, "hark.log")
    }

    // MARK: - Edge cases

    /// Unicode in log bodies (emoji, RTL, combining diacriticals) must
    /// round-trip exactly — we encode UTF-8 and never strip. Crash
    /// reports occasionally include emoji-named exceptions, file paths
    /// with non-ASCII, etc.; losing bytes here would corrupt the log.
    func testUnicodeBodyRoundTrips() throws {
        let logger = FileLogger(directory: tempDir)
        let body = "héllo 🌍 שלום 日本語"
        logger.log(.info, category: "x", body)
        logger.flushSynchronously()

        let written = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        XCTAssertTrue(written.contains(body), "wrote: \(written)")
    }

    /// Empty-string body produces a valid (timestamp + level + category +
    /// blank tail) line. The logger should NOT skip empty bodies — they
    /// can be diagnostically meaningful as "we got here" markers.
    func testEmptyBodyStillWritesLine() throws {
        let logger = FileLogger(directory: tempDir)
        logger.log(.info, category: "marker", "")
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        let lines = body.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1)
        XCTAssertTrue(lines[0].hasSuffix("[INFO] [marker] "), "line was: \(lines[0])")
    }

    /// Stress: 1k entries in a single thread. Verifies the logger doesn't
    /// fall behind / drop lines / wedge under sustained load.
    func testStressOneThousandLines() throws {
        let logger = FileLogger(directory: tempDir)
        for i in 0..<1000 {
            logger.log(.info, category: "x", "msg-\(i)")
        }
        logger.flushSynchronously()

        let body = try String(contentsOf: tempDir.appending(path: "hark.log"), encoding: .utf8)
        let lines = body.split(separator: "\n").map(String.init)
        XCTAssertEqual(lines.count, 1000, "expected 1000 lines, got \(lines.count)")
    }

    func testCurrentLogsIncludesRotatedFile() {
        let logger = FileLogger(directory: tempDir, maxFileSize: 100)
        for i in 0..<50 {
            logger.log(.info, category: "x", "rotate me \(i)")
        }
        logger.flushSynchronously()

        let logs = logger.currentLogs()
        XCTAssertEqual(logs.count, 2)
        XCTAssertEqual(
            Set(logs.map(\.lastPathComponent)),
            ["hark.log", "hark.log.1"]
        )
    }
}
