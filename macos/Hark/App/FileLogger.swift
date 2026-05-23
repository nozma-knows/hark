import Foundation
import OSLog

/// Lightweight rotating file logger that mirrors important events to a
/// directory on disk (default: `~/Library/Logs/Hark/`). `os.Logger` writes
/// go to the system log database, which is fine for `log show` on a dev
/// machine but invisible to end users who hit a bug and need to send us
/// a file.
///
/// Why a separate channel instead of a unified `Logger` extension:
///   - `os.Logger` doesn't expose its sink, so we can't intercept its
///     writes; we have to choose to emit to both os_log AND this file.
///   - Most call sites want just os_log; only events worth shipping to
///     support use `FileLogger.shared.log(...)`.
///
/// Threading: all file I/O runs on a private serial queue. Callers may be
/// on ANY thread (`@MainActor`, sidecar reader, audio tap callback). No
/// actor isolation is required — the queue serializes writes, and the
/// file handle is only ever touched from within the queue.
///
/// Rotation: when the active log exceeds `maxFileSize`, we rotate to
/// `hark.log.1` and start fresh. We keep one rotation generation — two
/// log files total — which is enough context for any single bug report
/// without unbounded disk growth.
///
/// Testability: the singleton uses the default `~/Library/Logs/Hark/`
/// directory; tests construct their own instances with a temp directory
/// via the `init(directory:)` initializer.
final class FileLogger: @unchecked Sendable {
    static let shared = FileLogger()

    enum Level: String {
        case info = "INFO"
        case warning = "WARN"
        case error = "ERROR"
    }

    /// Rotate after the active file exceeds this many bytes. 2 MB is
    /// plenty for ~10k log lines while still being small enough to
    /// email or paste into an issue.
    private let maxFileSize: Int

    let logDirectory: URL
    let logFileURL: URL
    private let rotatedURL: URL
    private let queue: DispatchQueue
    private let formatter: ISO8601DateFormatter
    private var handle: FileHandle?

    /// Production initializer — writes to `~/Library/Logs/Hark/`.
    private convenience init() {
        let fm = FileManager.default
        let libraryLogs = fm.urls(for: .libraryDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library")
        let dir = libraryLogs.appending(path: "Logs/Hark", directoryHint: .isDirectory)
        self.init(directory: dir, maxFileSize: 2 * 1024 * 1024)
    }

    /// Designated initializer — tests construct an isolated instance with
    /// a temp directory and a small rotation threshold so they can
    /// exercise the rotation path without writing 2 MB of test fixtures.
    init(directory: URL, maxFileSize: Int = 2 * 1024 * 1024) {
        // Create the directory SYNCHRONOUSLY so by the time init returns,
        // the dir exists and subsequent log() calls don't race against
        // creation. (The previous implementation did this too, but the
        // audit confused itself about the queue.async openHandle path —
        // documenting explicitly here.)
        try? FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        logDirectory = directory
        logFileURL = directory.appending(path: "hark.log")
        rotatedURL = directory.appending(path: "hark.log.1")
        self.maxFileSize = maxFileSize

        // Background QoS — log writes must never compete with UI or audio
        // for CPU. Serial guarantees ordering even under bursty traffic.
        let label = "co.milbo.hark.filelogger.\(UUID().uuidString)"
        queue = DispatchQueue(label: label, qos: .utility)

        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        formatter = iso

        // Open the handle on the queue. Because subsequent `log()` calls
        // also dispatch to this same FIFO-serial queue, the open always
        // completes before the first write — no race possible.
        queue.async { [weak self] in
            self?.openHandle()
        }
    }

    /// Append a log entry. Safe to call from any thread; the write is
    /// dispatched to the serial queue, so the call site doesn't block on
    /// disk I/O. Order is preserved within a single thread of execution.
    func log(_ level: Level, category: String, _ message: @autoclosure () -> String) {
        let timestamp = formatter.string(from: Date())
        let body = message() // capture before crossing the queue boundary
        queue.async { [weak self] in
            self?.write(timestamp: timestamp, level: level, category: category, body: body)
        }
    }

    /// Block until all in-flight log writes have hit disk. Tests use this
    /// to make assertions deterministic. Production code generally
    /// shouldn't call this — the whole point of the async queue is to
    /// avoid blocking call sites.
    func flushSynchronously() {
        queue.sync {} // a no-op sync barrier — waits for all prior async items
    }

    /// Returns the bundle of log file URLs (current + rotated, if any).
    /// Settings exposes "Reveal in Finder" which highlights these so the
    /// user can attach to a support email.
    func currentLogs() -> [URL] {
        var urls: [URL] = []
        if FileManager.default.fileExists(atPath: logFileURL.path) {
            urls.append(logFileURL)
        }
        if FileManager.default.fileExists(atPath: rotatedURL.path) {
            urls.append(rotatedURL)
        }
        return urls
    }

    // MARK: - Queue-confined I/O

    private func write(timestamp: String, level: Level, category: String, body: String) {
        guard let handle else {
            openHandle()
            if handle == nil { return }
            return write(timestamp: timestamp, level: level, category: category, body: body)
        }
        let line = "\(timestamp) [\(level.rawValue)] [\(category)] \(body)\n"
        guard let data = line.data(using: .utf8) else { return }
        do {
            try handle.write(contentsOf: data)
            rotateIfNeeded()
        } catch {
            // Logging failures must never crash the app. Drop the handle
            // and let the next call reopen — better silent loss than a
            // logger-induced crash.
            try? handle.close()
            self.handle = nil
        }
    }

    private func openHandle() {
        let fm = FileManager.default
        if !fm.fileExists(atPath: logFileURL.path) {
            fm.createFile(atPath: logFileURL.path, contents: nil)
        }
        handle = try? FileHandle(forWritingTo: logFileURL)
        _ = try? handle?.seekToEnd()
    }

    private func rotateIfNeeded() {
        guard let handle else { return }
        let size = (try? handle.offset()) ?? 0
        guard size > UInt64(maxFileSize) else { return }

        try? handle.close()
        let fm = FileManager.default
        try? fm.removeItem(at: rotatedURL)
        try? fm.moveItem(at: logFileURL, to: rotatedURL)
        openHandle()
    }
}

/// Combined os_log + FileLogger writer. Both sinks see the same message
/// in the same order, with no Task-wrapping or actor hops at the call site.
/// Use this anywhere you want the event to BOTH appear in `log show` AND
/// be capturable from `~/Library/Logs/Hark/`.
final class DualLogger: Sendable {
    private let osLog: Logger
    private let category: String

    init(subsystem: String = "co.milbo.hark", category: String) {
        osLog = Logger(subsystem: subsystem, category: category)
        self.category = category
    }

    func info(_ message: String) {
        osLog.info("\(message, privacy: .public)")
        FileLogger.shared.log(.info, category: category, message)
    }

    func warning(_ message: String) {
        osLog.warning("\(message, privacy: .public)")
        FileLogger.shared.log(.warning, category: category, message)
    }

    func error(_ message: String) {
        osLog.error("\(message, privacy: .public)")
        FileLogger.shared.log(.error, category: category, message)
    }
}
