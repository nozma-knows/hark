@testable import Hark
import XCTest

/// Performance budgets for the hot paths. These tests don't just measure
/// — they assert against documented ceilings so a regression that doubles
/// log latency or panel state derivation fails CI loudly.
///
/// The numbers are chosen with 5× headroom over typical observed times
/// on an M1 Pro running tests under XCTest's instrumentation overhead.
/// Tighten them when we have CI runner baselines; loosen if a slower
/// runner family starts flaking.
final class PerformanceTests: XCTestCase {
    // MARK: - FileLogger throughput

    /// 1000 sequential log writes should complete in under 200ms,
    /// including the synchronous flush at the end. The serial queue is
    /// the bottleneck; if someone refactors away the queue (or replaces
    /// it with a slower sync-per-write design), this test catches the
    /// regression.
    func testFileLoggerThroughputUnder200ms() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "perf-flog-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }
        let logger = FileLogger(directory: tmpDir)

        let start = Date()
        for i in 0..<1000 {
            logger.log(.info, category: "perf", "msg-\(i)")
        }
        logger.flushSynchronously()
        let elapsed = Date().timeIntervalSince(start)

        XCTAssertLessThan(elapsed, 0.2, "1000 log writes took \(elapsed)s — threshold 0.2s")
    }

    // MARK: - PanelViewModel mode derivation

    /// The pill's UI mode is computed on every Observable refresh. It
    /// must be sub-microsecond to keep panel updates smooth. 10k
    /// iterations under 20ms (2µs each, with 5× headroom) — fails if
    /// someone slips an expensive operation into the priority switch.
    func testPanelViewModelModeUnder20ms() {
        let start = Date()
        for _ in 0..<10000 {
            _ = PanelViewModel.mode(
                recorderState: .idle,
                transcriberState: .ready(.default),
                isExecutingCommand: false,
                isPolishing: false,
                commandResult: nil,
                transcript: "hello"
            )
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.02, "10k mode evaluations took \(elapsed)s — threshold 0.02s")
    }

    // MARK: - CrashReporter breadcrumb decode

    /// Decode is called once per launch on the next-launch finalizer.
    /// 10k decodes under 50ms verifies the byte-level parse isn't doing
    /// anything pathologically slow. (Mostly defensive — the function
    /// reads a fixed 64-byte structure.)
    func testCrashReporterDecodeUnder50ms() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "perf-breadcrumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }
        let fd = tmp.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = fd
        defer { CrashReporter.breadcrumbFD = savedFD }
        CrashReporter.writeBreadcrumb(signal: SIGSEGV)
        close(fd)
        let data = try Data(contentsOf: tmp)

        let start = Date()
        for _ in 0..<10000 {
            _ = CrashReporter.decodeBreadcrumb(data)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "10k breadcrumb decodes took \(elapsed)s — threshold 0.05s")
    }

    // MARK: - HotkeyManager modifier resolution

    /// `resolveTrigger` runs on every flagsChanged event the kernel
    /// delivers — potentially many per second when the user is typing
    /// modifier-laden shortcuts. Must be effectively free; 1M calls
    /// under 250ms (~250ns each). The threshold accommodates Debug-build
    /// overhead (no inlining, ObjC dispatch via @objc bridging for the
    /// static method); Release builds run ~5× faster. The kernel
    /// delivers maybe 10-100 events/sec in practice, so even at
    /// 250ns/call we're nowhere near a bottleneck.
    func testHotkeyResolveTriggerUnder250ms() {
        let start = Date()
        for i in 0..<1_000_000 {
            let ctrl = (i & 1) != 0
            let shift = (i & 2) != 0
            _ = HotkeyManager.resolveTrigger(ctrlDown: ctrl, shiftDown: shift)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.25, "1M resolveTrigger calls took \(elapsed)s — threshold 0.25s")
    }

    // MARK: - ClaudeUsage accumulation

    /// `add` runs once per Claude call. 100k iterations under 50ms
    /// (500ns each) — fails if someone adds expensive validation or
    /// disk I/O inside the math path. The `save()` it triggers in the
    /// orchestrator IS slow (UserDefaults), but `add` alone shouldn't be.
    func testClaudeUsageAddUnder50ms() {
        var usage = ClaudeUsage()
        let start = Date()
        for _ in 0..<100_000 {
            usage.add(input: 100, output: 50, cacheRead: 10, cacheCreation: 5)
        }
        let elapsed = Date().timeIntervalSince(start)
        XCTAssertLessThan(elapsed, 0.05, "100k usage.add calls took \(elapsed)s — threshold 0.05s")
    }
}
