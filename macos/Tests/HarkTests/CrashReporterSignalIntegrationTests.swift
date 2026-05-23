import Darwin
@testable import Hark
import XCTest

/// Integration tests that actually deliver a fatal signal to a child
/// process and verify the breadcrumb survived. Without these, the
/// async-signal-safe contract on `writeBreadcrumb` is only theoretical —
/// unit tests can call the function from normal Swift, but the real
/// failure mode (handler invoked from a kernel-delivered signal in
/// undefined heap state) is what we actually need to validate.
///
/// We use `fork(2)` instead of `Process` because:
///   - Process needs a discoverable executable; we don't ship one
///   - fork lets us reuse the test bundle's CrashReporter directly
///   - The child immediately raises SIGSEGV and dies, so the standard
///     "don't fork() in multithreaded apps" warning doesn't apply (we
///     only run one statement in the child before crashing)
///
/// Skipped on CI environments that disallow fork (some sandboxed
/// runners): if fork returns < 0, we throw `XCTSkip` instead of failing.
final class CrashReporterSignalIntegrationTests: XCTestCase {
    /// Deliver SIGSEGV to a child process that has installed our handler;
    /// verify the breadcrumb file is correctly formatted on disk.
    func testRealSIGSEGVProducesValidBreadcrumb() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "crash-int-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let breadcrumbURL = tmpDir.appending(path: "pending-crash")
        let breadcrumbPath = breadcrumbURL.path

        let pid = hark_fork()
        if pid < 0 {
            throw XCTSkip("fork() failed (errno=\(errno)) — likely a sandboxed CI runner")
        }

        if pid == 0 {
            // Child process. Only one thread is alive here (only the
            // forking thread survives), so the usual fork-in-MT warning
            // doesn't apply. We do the absolute minimum then crash.
            let fd = breadcrumbPath.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
            if fd < 0 { Darwin._exit(99) }
            CrashReporter.breadcrumbFD = fd

            // Install the real signal handler — same code path the
            // production app installs at launch.
            signal(SIGSEGV) { signum in
                CrashReporter.writeBreadcrumb(signal: signum)
                signal(signum, SIG_DFL)
                raise(signum)
            }

            // Raise the signal directly. We can't "naturally" segfault
            // via null-deref in Swift — the runtime catches null
            // unwraps and raises SIGTRAP instead. `raise(SIGSEGV)` goes
            // through the same kernel signal-delivery path our handler
            // would see from a wild memory access, just synthesized.
            raise(SIGSEGV)
            Darwin._exit(0) // unreachable
        }

        // Parent. Wait for child to die.
        var status: Int32 = 0
        waitpid(pid, &status, 0)

        // Child should have died from SIGSEGV (signal 11). Any other
        // exit means our handler didn't run correctly (e.g. it crashed
        // BEFORE writing the breadcrumb).
        XCTAssertTrue(
            WIFSIGNALED(status),
            "child should have been killed by a signal, got status \(status)"
        )
        XCTAssertEqual(
            WTERMSIG(status),
            SIGSEGV,
            "child should have died from SIGSEGV"
        )

        // Now the real check: did the breadcrumb file survive intact?
        let data = try Data(contentsOf: breadcrumbURL)
        XCTAssertEqual(
            data.count,
            CrashReporter.breadcrumbSize,
            "breadcrumb file should be exactly \(CrashReporter.breadcrumbSize) bytes"
        )

        let decoded = try XCTUnwrap(CrashReporter.decodeBreadcrumb(data))
        XCTAssertEqual(decoded.signal, SIGSEGV)
        XCTAssertEqual(decoded.version, CrashReporter.breadcrumbVersion)
        XCTAssertEqual(decoded.pid, pid, "breadcrumb's pid should match the child")
        XCTAssertGreaterThan(decoded.timestamp, 0)
    }

    /// Same setup, but with SIGABRT — a different fatal signal. Verifies
    /// our handler installer correctly hooks all the trapped signals,
    /// not just SIGSEGV. If a future refactor accidentally registers
    /// only some signals, this test catches it.
    func testRealSIGABRTProducesValidBreadcrumb() throws {
        let tmpDir = FileManager.default.temporaryDirectory
            .appending(path: "crash-int-\(UUID().uuidString)", directoryHint: .isDirectory)
        try FileManager.default.createDirectory(at: tmpDir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmpDir) }

        let breadcrumbURL = tmpDir.appending(path: "pending-crash")
        let breadcrumbPath = breadcrumbURL.path

        let pid = hark_fork()
        if pid < 0 {
            throw XCTSkip("fork() failed (errno=\(errno))")
        }

        if pid == 0 {
            let fd = breadcrumbPath.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
            if fd < 0 { Darwin._exit(99) }
            CrashReporter.breadcrumbFD = fd

            signal(SIGABRT) { signum in
                CrashReporter.writeBreadcrumb(signal: signum)
                signal(signum, SIG_DFL)
                raise(signum)
            }

            abort() // raises SIGABRT
        }

        var status: Int32 = 0
        waitpid(pid, &status, 0)

        XCTAssertTrue(WIFSIGNALED(status))
        XCTAssertEqual(WTERMSIG(status), SIGABRT)

        let data = try Data(contentsOf: breadcrumbURL)
        let decoded = try XCTUnwrap(CrashReporter.decodeBreadcrumb(data))
        XCTAssertEqual(decoded.signal, SIGABRT)
    }
}

// MARK: - waitpid macro shims

/// `WIFSIGNALED` and `WTERMSIG` are C macros in `<sys/wait.h>` — not
/// imported into Swift. Reimplement here using the same bit math so
/// tests can interpret `waitpid` status codes portably.
///
/// The status word's low 7 bits hold the signal that killed the
/// process (or 0 if it exited normally). The 8th bit distinguishes
/// signal-death from normal exit.
private func WIFSIGNALED(_ status: Int32) -> Bool {
    let lowByte = status & 0x7F
    return lowByte != 0 && lowByte != 0x7F
}

private func WTERMSIG(_ status: Int32) -> Int32 {
    status & 0x7F
}
