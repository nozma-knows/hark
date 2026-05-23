import Foundation

/// Next-launch crash finalizer + NSException handler. Both paths run in
/// normal Swift land (NOT signal context) so they can use Foundation,
/// allocate, format strings, call the sink — all the things
/// CrashBreadcrumb.swift cannot.
extension CrashReporter {
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

    // MARK: - NSException handler (full Swift land — no signal safety needed)

    static func installExceptionHandler() {
        // @convention(c) — no captures. Fully qualify every reference inside
        // the closure so the compiler treats them as static lookups, not
        // captured variables.
        NSSetUncaughtExceptionHandler { exception in
            let payload = CrashReporter.CrashPayload(
                kind: "NSException",
                detail: "\(exception.name.rawValue): \(exception.reason ?? "no reason")",
                stack: exception.callStackSymbols,
                signal: nil,
                timestamp: Date()
            )
            CrashReporter.writeReport(payload)
            // Forward directly — we're on the throwing thread, not in a
            // signal context. The forwarder is responsible for being
            // thread-safe.
            CrashReporter.sink?.capture(payload)
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
}
