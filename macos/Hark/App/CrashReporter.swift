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
/// process terminates cleanly.
///
/// Stage 2 (next launch): `finalizePendingCrashIfAny()` reads the
/// breadcrumb under normal Swift conditions, formats a human-readable
/// `.log` under `~/Library/Logs/Hark/crashes/`, deletes the breadcrumb,
/// and (optionally) forwards to a backend like Sentry.
///
/// NSException handler is NOT subject to async-signal-safety — it runs in
/// normal Obj-C/Swift land — so that path writes the full report directly.
enum CrashReporter {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "CrashReporter")

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
    /// no network calls; wire your DSN-bearing implementation here when
    /// ready. Called from the next-launch finalizer AND the NSException
    /// handler — both run in normal Swift land (not signal context).
    ///
    /// `nonisolated(unsafe)` because the NSException handler is a
    /// `@convention(c)` function pointer that must read this without
    /// holding an actor. Implementations are responsible for being
    /// thread-safe (production SDKs like Sentry already are).
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

    // MARK: - Binary breadcrumb format

    //
    // Fixed 64-byte layout written from the signal handler:
    //   [0..8)   magic       UInt64  "HarkCrah" little-endian
    //   [8..12)  version     UInt32  (currently 1)
    //   [12..16) signal      Int32
    //   [16..24) timestamp   Int64   seconds since epoch
    //   [24..28) pid         Int32
    //   [28..64) reserved    36 bytes of zero, for future fields
    //
    // The size is constant and known at compile time. We never serialize
    // anything dynamic — pre-computed at install time, written verbatim.

    static let breadcrumbMagic: UInt64 = 0x4861_726B_4372_6168 // "HarkCrah" big-endian view
    static let breadcrumbVersion: UInt32 = 1
    static let breadcrumbSize = 64

    /// Raw FD opened ONCE at install time. The signal handler writes to this
    /// FD without any per-call open()/close() calls. Static so the
    /// @convention(c) handler closure can reach it without a capture.
    nonisolated(unsafe) static var breadcrumbFD: Int32 = -1

    // MARK: - Install: filesystem prep

    /// Synchronously create `~/Library/Logs/Hark/crashes/` so the
    /// breadcrumb FD has somewhere to land. Failing here is logged but
    /// non-fatal — we still install the rest of the handlers; the next
    /// launch finalizer will simply find no breadcrumb.
    private static func ensureCrashDirectoryExists() {
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

    // MARK: - Install: open the breadcrumb FD

    /// Open (create + truncate) the breadcrumb file and stash the FD as a
    /// process-global. Done OUTSIDE the signal handler so `open(2)` —
    /// which is itself async-signal-safe but allocates kernel structures
    /// — happens at a known-safe time.
    private static func openBreadcrumbFD() {
        if breadcrumbFD >= 0 {
            close(breadcrumbFD)
            breadcrumbFD = -1
        }
        let path = breadcrumbURL().path
        // O_WRONLY | O_CREAT | O_TRUNC, mode 0644
        let fd = path.withCString { open($0, O_WRONLY | O_CREAT | O_TRUNC, 0o644) }
        if fd < 0 {
            logger.error("breadcrumb open failed: errno=\(errno)")
            return
        }
        breadcrumbFD = fd
    }

    // MARK: - Install: signal handlers

    /// Trapped signals. Excludes SIGKILL/SIGSTOP (uncatchable) and signals
    /// the OS uses for normal lifecycle events (SIGCHLD, SIGPIPE).
    static let trappedSignals: [Int32] = [
        SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP, SIGSYS
    ]

    private static func installSignalHandlers() {
        for sig in trappedSignals {
            // @convention(c) closure: NO captures. Calls only:
            //   - CrashReporter.writeBreadcrumb(signal:) (write(2) only)
            //   - signal(2) / raise(2)
            // Both are documented async-signal-safe (POSIX.1-2008).
            signal(sig) { signum in
                Self.writeBreadcrumb(signal: signum)
                signal(signum, SIG_DFL)
                raise(signum)
            }
        }
    }

    // MARK: - Signal-context code (must stay async-signal-safe)

    /// Write a 64-byte breadcrumb to the pre-opened FD. The buffer is
    /// stack-allocated (no heap), bytes are filled via raw memory writes
    /// (no Swift String, no Foundation), and only `write(2)` / `fsync(2)` /
    /// `time(3)` / `getpid(2)` are called — all on the POSIX safe list.
    ///
    /// **DO NOT** add any allocating call to this function. If you need
    /// richer crash data, defer it to the next-launch finalizer.
    static func writeBreadcrumb(signal sig: Int32) {
        guard breadcrumbFD >= 0 else { return }
        var buffer = [UInt8](repeating: 0, count: breadcrumbSize)
        let now = time(nil)
        let pid = getpid()
        buffer.withUnsafeMutableBytes { raw in
            guard let base = raw.baseAddress else { return }
            // magic (8 bytes, big-endian so a hex dump shows "Hark Crah")
            var magicBE = breadcrumbMagic.bigEndian
            memcpy(base, &magicBE, 8)
            // version (4 bytes)
            var ver = breadcrumbVersion
            memcpy(base.advanced(by: 8), &ver, 4)
            // signal (4 bytes)
            var s = sig
            memcpy(base.advanced(by: 12), &s, 4)
            // timestamp (8 bytes, seconds since epoch as Int64)
            var ts = Int64(now)
            memcpy(base.advanced(by: 16), &ts, 8)
            // pid (4 bytes)
            var p = pid
            memcpy(base.advanced(by: 24), &p, 4)
            // reserved (28..64) stays zero
        }
        _ = buffer.withUnsafeBytes { ptr in
            write(breadcrumbFD, ptr.baseAddress, breadcrumbSize)
        }
        fsync(breadcrumbFD)
    }

    // MARK: - Next-launch finalizer (normal Swift land)

    /// Inspect the breadcrumb file from the prior session. If present and
    /// well-formed, format a full crash report under `crashes/` and delete
    /// the breadcrumb. Idempotent — subsequent calls without a fresh crash
    /// are no-ops.
    static func finalizePendingCrashIfAny() {
        finalizePendingCrash(in: crashDirectory())
    }

    /// Testable variant: read the breadcrumb from a specific directory and
    /// write the formatted report there. The production caller passes
    /// `crashDirectory()` (which derives from FileLogger.shared); tests
    /// pass a fresh temp dir so they can exercise the format-and-delete
    /// cycle in isolation.
    static func finalizePendingCrash(in directory: URL) {
        let url = directory.appending(path: ".pending-crash")
        guard let data = try? Data(contentsOf: url) else { return }
        defer { try? FileManager.default.removeItem(at: url) }
        guard let crumb = decodeBreadcrumb(data) else {
            logger.warning("breadcrumb malformed (size=\(data.count, privacy: .public))")
            return
        }
        let payload = CrashPayload(
            kind: "Signal",
            detail: "\(signalName(crumb.signal)) (\(crumb.signal))",
            stack: [],
            signal: crumb.signal,
            timestamp: Date(timeIntervalSince1970: TimeInterval(crumb.timestamp))
        )
        writeReport(payload, in: directory)
        sink?.capture(payload)
    }

    /// Decode a 64-byte breadcrumb. Returns nil if size or magic is wrong;
    /// safe to call on garbage data. Pure function — unit-testable.
    static func decodeBreadcrumb(_ data: Data) -> DecodedBreadcrumb? {
        guard data.count >= breadcrumbSize else { return nil }
        return data.withUnsafeBytes { raw -> DecodedBreadcrumb? in
            guard let base = raw.baseAddress else { return nil }
            var magicBE: UInt64 = 0
            memcpy(&magicBE, base, 8)
            let magic = UInt64(bigEndian: magicBE)
            guard magic == breadcrumbMagic else { return nil }
            var version: UInt32 = 0
            memcpy(&version, base.advanced(by: 8), 4)
            var sig: Int32 = 0
            memcpy(&sig, base.advanced(by: 12), 4)
            var ts: Int64 = 0
            memcpy(&ts, base.advanced(by: 16), 8)
            var pid: Int32 = 0
            memcpy(&pid, base.advanced(by: 24), 4)
            return DecodedBreadcrumb(
                version: version,
                signal: sig,
                timestamp: ts,
                pid: pid
            )
        }
    }

    /// Pure value type for the decoded breadcrumb. Public so tests can
    /// assert on individual fields without comparing raw bytes.
    struct DecodedBreadcrumb: Equatable {
        let version: UInt32
        let signal: Int32
        let timestamp: Int64
        let pid: Int32
    }

    // MARK: - NSException handler (full Swift land — no signal safety needed)

    private static func installExceptionHandler() {
        // @convention(c) — no captures. Fully qualify every reference inside
        // the closure so the compiler treats them as static lookups, not
        // captured variables.
        NSSetUncaughtExceptionHandler { exception in
            let payload = Self.CrashPayload(
                kind: "NSException",
                detail: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                stack: exception.callStackSymbols,
                signal: nil,
                timestamp: Date()
            )
            Self.writeReport(payload)
            // Forward directly — we're on the throwing thread, not in a
            // signal context. The forwarder is responsible for being
            // thread-safe (Sentry SDK already handles this).
            Self.sink?.capture(payload)
        }
    }

    // MARK: - Report writer (runs on normal Swift; not in signal context)

    /// Write the full crash report to a timestamped file under `crashes/`.
    /// Safe to call from any Obj-C exception handler (runs in normal Swift
    /// runtime) or from the next-launch finalizer.
    static func writeReport(_ payload: CrashPayload) {
        writeReport(payload, in: crashDirectory())
    }

    /// Testable variant — same as above but writes into a caller-supplied
    /// directory. The production caller (NSException handler, finalizer)
    /// uses `crashDirectory()`; tests use a fresh temp dir.
    static func writeReport(_ payload: CrashPayload, in directory: URL) {
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withInternetDateTime]
        let filename = "crash-\(formatter.string(from: payload.timestamp)).log"
        let url = directory.appending(path: filename)

        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "?"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"
        let body = payload.formattedReport(appVersion: version, build: build, pid: getpid())
        try? body.write(to: url, atomically: true, encoding: .utf8)

        FileLogger.shared.log(
            .error,
            category: "CrashReporter",
            "captured \(payload.kind): \(payload.detail) → \(url.lastPathComponent)"
        )
    }

    // MARK: - Signal name table (no allocation — array of static strings)

    /// Static, allocation-free lookup. Returns "SIG(N)" for unknown signals
    /// so the caller never gets a nil that needs handling.
    static func signalName(_ sig: Int32) -> String {
        switch sig {
        case SIGABRT: "SIGABRT"
        case SIGILL: "SIGILL"
        case SIGSEGV: "SIGSEGV"
        case SIGFPE: "SIGFPE"
        case SIGBUS: "SIGBUS"
        case SIGTRAP: "SIGTRAP"
        case SIGSYS: "SIGSYS"
        default: "SIG(\(sig))"
        }
    }
}

/// Extension point for crash-telemetry backends. Set
/// `CrashReporter.sink = MyImpl()` at app launch to route every captured
/// crash to a telemetry pipeline. Implementations:
///
/// - **No-op** (production default): nil. Crashes stay in
///   `~/Library/Logs/Hark/crashes/` only.
/// - **Sentry**: a thin wrapper around `SentrySDK.capture(message:)`
///   that maps `CrashReporter.CrashPayload` to Sentry's event model.
///   Wire this when you have a DSN.
/// - **Crashlytics / Rollbar / custom**: same pattern.
/// - **Tests**: an array-collecting recorder that asserts captured
///   payloads.
///
/// The protocol is intentionally narrow — one method, value-typed
/// payload, no setup/teardown lifecycle. Backends manage their own
/// state internally. `Sendable` because the sink is invoked from the
/// NSException handler (any thread) AND the next-launch finalizer.
protocol CrashReportSink: Sendable {
    func capture(_ payload: CrashReporter.CrashPayload)
}
