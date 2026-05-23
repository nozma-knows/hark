import Darwin
import Foundation
import OSLog

/// Two-stage in-process crash capture, designed to comply with POSIX
/// async-signal-safety rules.
///
/// The signal handler is the only piece of code that runs in the
/// undefined-behavior zone (after a fatal signal, inside the kernel-
/// delivered handler). It is restricted to:
///   - `write(2)` to a file descriptor we opened at install time
///   - `signal(2)` + `raise(2)` to chain to the default handler
///   - Pure arithmetic on stack-allocated values
///
/// That means **no String allocation, no FileManager, no Date, no method
/// dispatch, no Swift heap touches** inside the handler. Anything richer
/// would risk deadlock (malloc lock held by the crashed thread), heap
/// corruption (mid-allocation when the signal fired), or infinite
/// recursion (if the formatter itself crashes).
///
/// Stage 1 (in-signal): drop a 64-byte binary "breadcrumb" file recording
/// what signal fired, the timestamp, and the pid. Then restore the default
/// handler and re-raise so macOS produces its own `.ips` report and the
/// process terminates cleanly. **See CrashBreadcrumb.swift** for the
/// async-signal-safe code path — it lives in its own file precisely so
/// the constraint is visible at the file boundary.
///
/// Stage 2 (next launch): `finalizePendingCrashIfAny()` reads the
/// breadcrumb under normal Swift conditions, formats a human-readable
/// `.log` under `~/Library/Logs/Hark/crashes/`, deletes the breadcrumb,
/// and (optionally) forwards to a backend like Sentry. **See
/// CrashFinalizer.swift** for the next-launch + NSException paths.
///
/// NSException handler is NOT subject to async-signal-safety — it runs in
/// normal Obj-C/Swift land — so that path writes the full report directly.
enum CrashReporter {
    static let logger = Logger(subsystem: "co.milbo.hark", category: "CrashReporter")

    // MARK: - Public surface

    /// Wire up the handlers. Must be called once, very early in app launch
    /// (before any code that could throw or segfault). Idempotent — calling
    /// twice replaces handlers and reopens the breadcrumb FD.
    static func install() {
        ensureCrashDirectoryExists()
        finalizePendingCrashIfAny()
        openBreadcrumbFD()
        installSignalHandlers()
        installExceptionHandler()
        logger.info("CrashReporter installed")
        FileLogger.shared.log(.info, category: "CrashReporter", "installed")
    }

    /// Forwarding hook for a real telemetry backend (Sentry, Rollbar,
    /// Crashlytics, etc.). Stays nil in the MVP so the binary ships with
    /// no network calls; production HttpCrashSink wires here when the user
    /// opts in via Settings → General → Crash uploads. Called from the
    /// next-launch finalizer AND the NSException handler — both run in
    /// normal Swift land (not signal context).
    ///
    /// `nonisolated(unsafe)` because the NSException handler is a
    /// `@convention(c)` function pointer that must read this without
    /// holding an actor. Implementations are responsible for being
    /// thread-safe.
    nonisolated(unsafe) static var sink: (any CrashReportSink)?

    // MARK: - Crash payload (cross-stage type)

    struct CrashPayload: Equatable {
        let kind: String
        let detail: String
        let stack: [String]
        let signal: Int32?
        let timestamp: Date

        /// Format the payload for the on-disk crash report file. Pure;
        /// trivial to unit-test.
        func formattedReport(appVersion: String, build: String, pid: Int32) -> String {
            var body = """
            Hark crash report
            =================
            Version:   \(appVersion) (\(build))
            Timestamp: \(timestamp)
            Kind:      \(kind)
            Detail:    \(detail)
            PID:       \(pid)
            """
            if !stack.isEmpty {
                body += "\n\nStack trace\n-----------\n"
                for (i, frame) in stack.enumerated() {
                    body += "\(i)\t\(frame)\n"
                }
            } else {
                body += "\n\n(no stack — cross-reference ~/Library/Logs/DiagnosticReports/Hark_*.ips)\n"
            }
            return body
        }
    }

    // MARK: - Install: filesystem prep

    /// Synchronously create `~/Library/Logs/Hark/crashes/` so the
    /// breadcrumb FD has somewhere to land. Failing here is logged but
    /// non-fatal — we still install the rest of the handlers; the next
    /// launch finalizer will simply find no breadcrumb.
    static func ensureCrashDirectoryExists() {
        let dir = crashDirectory()
        do {
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
        } catch {
            logger.error("crash dir create failed: \(String(describing: error), privacy: .public)")
        }
    }

    static func crashDirectory() -> URL {
        FileLogger.shared.logDirectory.appending(path: "crashes", directoryHint: .isDirectory)
    }

    static func breadcrumbURL() -> URL {
        crashDirectory().appending(path: ".pending-crash")
    }
}

/// Extension point for crash-telemetry backends. Set
/// `CrashReporter.sink = MyImpl()` at app launch to route every captured
/// crash to a telemetry pipeline. The production HttpCrashSink ships in
/// the binary but stays disabled unless the user configures an endpoint
/// in Settings.
///
/// The protocol is intentionally narrow — one method, value-typed
/// payload, no setup/teardown lifecycle. Backends manage their own
/// state internally. `Sendable` because the sink is invoked from the
/// NSException handler (any thread) AND the next-launch finalizer.
protocol CrashReportSink: Sendable {
    func capture(_ payload: CrashReporter.CrashPayload)
}
