import Darwin
@testable import Hark
import XCTest

/// CrashReporter has two parts:
///   1. The signal-context binary breadcrumb (async-signal-safe writer)
///   2. The next-launch finalizer that decodes the breadcrumb and writes
///      a human-readable report
///
/// We can't test the live signal handler directly without spawning a
/// child process that crashes — covered separately in
/// `CrashReporterSignalIntegrationTests` via `kill -SEGV`. These unit
/// tests pin down the breadcrumb format, the decoder, and the formatter
/// in isolation.
final class CrashReporterTests: XCTestCase {
    // MARK: - Breadcrumb round-trip

    /// Validates the manual byte-layout writer + decoder match exactly:
    /// magic, version, signal, timestamp, pid.
    func testBreadcrumbRoundTripsThroughDecode() throws {
        let tmp = FileManager.default.temporaryDirectory
            .appending(path: "breadcrumb-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: tmp) }

        // Hand-write the breadcrumb the same way the signal handler would.
        let fd = tmp.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = fd
        defer {
            CrashReporter.breadcrumbFD = savedFD
        }

        CrashReporter.writeBreadcrumb(signal: SIGSEGV)
        close(fd)

        let data = try Data(contentsOf: tmp)
        XCTAssertEqual(data.count, CrashReporter.breadcrumbSize, "exactly 64 bytes")

        let decoded = try XCTUnwrap(CrashReporter.decodeBreadcrumb(data))
        XCTAssertEqual(decoded.version, CrashReporter.breadcrumbVersion)
        XCTAssertEqual(decoded.signal, SIGSEGV)
        XCTAssertGreaterThan(decoded.timestamp, 0, "timestamp should be set")
        XCTAssertEqual(decoded.pid, getpid())
    }

    // MARK: - Decode rejects malformed input

    func testDecodeReturnsNilOnTooSmallData() {
        XCTAssertNil(CrashReporter.decodeBreadcrumb(Data()))
        XCTAssertNil(CrashReporter.decodeBreadcrumb(Data(repeating: 0, count: 32)))
        XCTAssertNil(CrashReporter.decodeBreadcrumb(Data(repeating: 0xFF, count: 63)))
    }

    func testDecodeReturnsNilOnWrongMagic() {
        // 64 bytes of garbage — magic doesn't match.
        let bogus = Data(repeating: 0xAA, count: 64)
        XCTAssertNil(CrashReporter.decodeBreadcrumb(bogus))
    }

    func testDecodeReturnsNilOnZeroFile() {
        // Pre-allocated but never written breadcrumb — all zeros.
        let zeros = Data(repeating: 0x00, count: 64)
        XCTAssertNil(CrashReporter.decodeBreadcrumb(zeros))
    }

    // MARK: - writeBreadcrumb is a no-op when no FD is set

    func testWriteBreadcrumbWithNoFDIsSafe() {
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = -1
        defer { CrashReporter.breadcrumbFD = savedFD }

        // Must not crash, must not raise, must not block.
        CrashReporter.writeBreadcrumb(signal: SIGSEGV)
    }

    // MARK: - Report formatter

    func testFormatterIncludesAllPayloadFields() {
        // Frames mimic the shape of real `Thread.callStackSymbols` output
        // — opaque demangled lines without their own index prefix (the
        // formatter prepends `0\t`, `1\t`, etc.).
        let payload = CrashReporter.CrashPayload(
            kind: "Signal",
            detail: "SIGSEGV (11)",
            stack: ["hark`main + 0x42", "dyld`start + 0x420"],
            signal: SIGSEGV,
            timestamp: Date(timeIntervalSince1970: 1_700_000_000)
        )
        let report = payload.formattedReport(appVersion: "0.1.3", build: "1", pid: 12345)

        XCTAssertTrue(report.contains("Hark crash report"))
        XCTAssertTrue(report.contains("Version:   0.1.3 (1)"))
        XCTAssertTrue(report.contains("Kind:      Signal"))
        XCTAssertTrue(report.contains("Detail:    SIGSEGV (11)"))
        XCTAssertTrue(report.contains("PID:       12345"))
        XCTAssertTrue(
            report.contains("0\thark`main + 0x42"),
            "stack frame not found in report:\n---\n\(report)\n---"
        )
        XCTAssertTrue(
            report.contains("1\tdyld`start + 0x420"),
            "stack frame not found in report:\n---\n\(report)\n---"
        )
    }

    func testFormatterHandlesEmptyStack() {
        let payload = CrashReporter.CrashPayload(
            kind: "Signal",
            detail: "SIGSEGV",
            stack: [],
            signal: SIGSEGV,
            timestamp: Date()
        )
        let report = payload.formattedReport(appVersion: "x", build: "y", pid: 1)

        XCTAssertFalse(report.contains("Stack trace"))
        XCTAssertTrue(
            report.contains("cross-reference"),
            "empty-stack hint should point users to the OS .ips file"
        )
    }

    // MARK: - Signal name lookup

    func testSignalNameKnownSignals() {
        XCTAssertEqual(CrashReporter.signalName(SIGABRT), "SIGABRT")
        XCTAssertEqual(CrashReporter.signalName(SIGSEGV), "SIGSEGV")
        XCTAssertEqual(CrashReporter.signalName(SIGBUS), "SIGBUS")
        XCTAssertEqual(CrashReporter.signalName(SIGFPE), "SIGFPE")
        XCTAssertEqual(CrashReporter.signalName(SIGILL), "SIGILL")
        XCTAssertEqual(CrashReporter.signalName(SIGTRAP), "SIGTRAP")
        XCTAssertEqual(CrashReporter.signalName(SIGSYS), "SIGSYS")
    }

    func testSignalNameUnknownReturnsSentinel() {
        XCTAssertEqual(CrashReporter.signalName(999), "SIG(999)")
    }

    // MARK: - Trapped-signals list

    func testAllTrappedSignalsHaveNames() {
        // Every signal we install a handler for must produce a non-empty
        // signal name (so the formatter has something to print).
        for sig in CrashReporter.trappedSignals {
            let name = CrashReporter.signalName(sig)
            XCTAssertFalse(name.isEmpty)
            XCTAssertNotEqual(name, "SIG(\(sig))", "named signal \(sig) fell through to sentinel")
        }
    }

    // MARK: - Async-signal-safety surface check (compile-time-ish)

    /// Not a runtime test — a structural check that `writeBreadcrumb` and
    /// `signalName` exist as static, free-of-instance-state functions. If
    /// someone refactors writeBreadcrumb to capture instance state from a
    /// MainActor object, this test would still pass (it doesn't introspect
    /// the call graph) but the next code review would catch it. The real
    /// safety check is in CrashReporterSignalIntegrationTests.
    func testWriteBreadcrumbIsStatic() {
        // Reference the function to ensure it's callable as a static.
        // Compile failure here means someone broke the contract.
        let _: (Int32) -> Void = CrashReporter.writeBreadcrumb(signal:)
    }

    // MARK: - Finalizer end-to-end

    /// The next-launch finalizer is the path that turns a binary
    /// breadcrumb into a human-readable crash log. End-to-end test:
    /// write a fake breadcrumb, call the finalizer, assert the formatted
    /// log file exists and contains the right signal/pid/timestamp,
    /// AND that the breadcrumb is consumed (deleted) so we don't
    /// double-report the same crash on subsequent launches.
    func testFinalizerWritesReportAndDeletesBreadcrumb() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "finalizer-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Manually craft a breadcrumb that mimics what the signal handler
        // would have written.
        let breadcrumbURL = tmpDir.appending(path: ".pending-crash")
        let fd = breadcrumbURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        XCTAssertGreaterThanOrEqual(fd, 0)
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = fd
        CrashReporter.writeBreadcrumb(signal: SIGABRT)
        close(fd)
        CrashReporter.breadcrumbFD = savedFD

        // Sanity: breadcrumb exists, formatted report doesn't yet.
        XCTAssertTrue(FileManager.default.fileExists(atPath: breadcrumbURL.path))
        let preFiles = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertEqual(preFiles, [".pending-crash"])

        // Run finalizer
        CrashReporter.finalizePendingCrash(in: tmpDir)

        // Breadcrumb should be gone now
        XCTAssertFalse(
            FileManager.default.fileExists(atPath: breadcrumbURL.path),
            "breadcrumb should be deleted after finalize"
        )

        // Exactly one formatted crash report should exist
        let postFiles = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let reportFiles = postFiles.filter { $0.hasPrefix("crash-") && $0.hasSuffix(".log") }
        XCTAssertEqual(reportFiles.count, 1, "expected one crash report, got: \(postFiles)")

        // Report content should mention SIGABRT
        if let reportName = reportFiles.first {
            let reportURL = tmpDir.appending(path: reportName)
            let body = try String(contentsOf: reportURL, encoding: .utf8)
            XCTAssertTrue(body.contains("SIGABRT"), "report body: \(body)")
            XCTAssertTrue(body.contains("Kind:      Signal"))
        }
    }

    /// Calling the finalizer when no breadcrumb exists is a normal startup
    /// path (most launches don't follow a crash). Must be a fast no-op.
    func testFinalizerNoOpWhenNoBreadcrumb() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "finalizer-empty-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // No breadcrumb file → finalizer should do nothing
        CrashReporter.finalizePendingCrash(in: tmpDir)

        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(files.isEmpty, "finalizer should not create files when no breadcrumb exists; got: \(files)")
    }

    // MARK: - CrashReportSink extension point

    /// A `CrashReportSink` plugged in via `CrashReporter.sink` receives
    /// every captured payload. This is the production hook for routing
    /// crashes to Sentry/Crashlytics/Rollbar/etc. — set `sink` once at
    /// app launch and the finalizer + NSException handler both call it.
    func testSinkReceivesFinalizedCrashPayload() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "sink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Prepare a breadcrumb the finalizer can consume
        let breadcrumbURL = tmpDir.appending(path: ".pending-crash")
        let fd = breadcrumbURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = fd
        CrashReporter.writeBreadcrumb(signal: SIGSEGV)
        close(fd)
        CrashReporter.breadcrumbFD = savedFD

        // Install a recording sink
        let recorder = RecordingCrashSink()
        let savedSink = CrashReporter.sink
        CrashReporter.sink = recorder
        defer { CrashReporter.sink = savedSink }

        CrashReporter.finalizePendingCrash(in: tmpDir)

        // The recorder should have captured exactly one payload, with
        // the right signal.
        XCTAssertEqual(recorder.captured.count, 1)
        XCTAssertEqual(recorder.captured.first?.signal, SIGSEGV)
        XCTAssertEqual(recorder.captured.first?.kind, "Signal")
    }

    /// Nil sink → no crash, no forwarding. Verifies the production
    /// default (no telemetry SDK wired) doesn't break the local-log
    /// capture path.
    func testFinalizerWorksWithoutSink() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "no-sink-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let breadcrumbURL = tmpDir.appending(path: ".pending-crash")
        let fd = breadcrumbURL.path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        let savedFD = CrashReporter.breadcrumbFD
        CrashReporter.breadcrumbFD = fd
        CrashReporter.writeBreadcrumb(signal: SIGABRT)
        close(fd)
        CrashReporter.breadcrumbFD = savedFD

        let savedSink = CrashReporter.sink
        CrashReporter.sink = nil
        defer { CrashReporter.sink = savedSink }

        // Should NOT crash, even with no sink configured
        CrashReporter.finalizePendingCrash(in: tmpDir)

        // Local report should still exist (the sink is OPTIONAL forwarding,
        // not the primary capture path)
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        XCTAssertTrue(files.contains { $0.hasPrefix("crash-") })
    }

    /// Malformed breadcrumb (wrong magic) — the finalizer must skip and
    /// delete the bad file rather than write garbage report. Defends
    /// against partial writes or older-format breadcrumbs from a prior
    /// installation.
    func testFinalizerDeletesMalformedBreadcrumb() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "finalizer-bad-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        // Write garbage where the breadcrumb should be
        let breadcrumbURL = tmpDir.appending(path: ".pending-crash")
        let garbage = Data(repeating: 0xAB, count: 64)
        try garbage.write(to: breadcrumbURL)

        CrashReporter.finalizePendingCrash(in: tmpDir)

        // Garbage should be deleted; NO report file should appear
        XCTAssertFalse(FileManager.default.fileExists(atPath: breadcrumbURL.path))
        let files = try FileManager.default.contentsOfDirectory(atPath: tmpDir.path)
        let reports = files.filter { $0.hasPrefix("crash-") }
        XCTAssertTrue(reports.isEmpty, "no report should be written for malformed breadcrumb; got: \(reports)")
    }
}

// MARK: - Recording sink for tests

/// Test double that captures every payload `CrashReporter` forwards.
/// Lets sink-routing tests assert on what the production code would have
/// sent to Sentry / Crashlytics / etc.
///
/// `@unchecked Sendable` because tests on MainActor write `captured`,
/// and the sink protocol allows invocation from any thread; we use an
/// NSLock to make that race-free.
final class RecordingCrashSink: CrashReportSink, @unchecked Sendable {
    private let lock = NSLock()
    private var _captured: [CrashReporter.CrashPayload] = []

    var captured: [CrashReporter.CrashPayload] {
        lock.lock()
        defer { lock.unlock() }
        return _captured
    }

    func capture(_ payload: CrashReporter.CrashPayload) {
        lock.lock()
        defer { lock.unlock() }
        _captured.append(payload)
    }
}
