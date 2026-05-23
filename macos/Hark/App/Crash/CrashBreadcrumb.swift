import Darwin
import Foundation

/// Async-signal-safe portion of the crash reporter. Everything in this
/// file runs from inside a fatal-signal handler, where the rules are:
///
///   - `write(2)`, `fsync(2)`, `time(3)`, `getpid(2)`, `signal(2)`,
///     `raise(2)`, `memcpy(3)` — all on POSIX's async-signal-safe list.
///   - NO Swift String allocation, no FileManager, no method dispatch on
///     classes, no Foundation calls that touch the heap, no Objective-C
///     message sends.
///   - Stack-allocated buffers only.
///
/// The file boundary is the constraint reminder. Adding helpers here
/// means signing up to read the POSIX async-signal-safety man page.
extension CrashReporter {
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

    /// Trapped signals. Excludes SIGKILL/SIGSTOP (uncatchable) and signals
    /// the OS uses for normal lifecycle events (SIGCHLD, SIGPIPE).
    static let trappedSignals: [Int32] = [
        SIGABRT, SIGILL, SIGSEGV, SIGFPE, SIGBUS, SIGTRAP, SIGSYS
    ]

    // MARK: - Install: open the breadcrumb FD

    /// Open (create + truncate) the breadcrumb file and stash the FD as a
    /// process-global. Done OUTSIDE the signal handler so `open(2)` —
    /// which is itself async-signal-safe but allocates kernel structures
    /// — happens at a known-safe time.
    static func openBreadcrumbFD() {
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

    static func installSignalHandlers() {
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

    // MARK: - Decode (runs on next launch, normal Swift land)

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
