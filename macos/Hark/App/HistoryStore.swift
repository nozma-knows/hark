import Foundation
import Observation
import OSLog

/// On-disk record of every transcript Hark has produced, plus the
/// outcome of the trigger that handled it (polish + paste, or command
/// execution). Surfaces through `HistoryView` for search, copy, and
/// re-run; never used as primary state — `AppState` still owns the
/// live pill content. Rotates at `maxEntries` so the file never grows
/// without bound on long-running installs.
///
/// Persistence format is JSON Lines (newline-delimited JSON, one entry
/// per line). Append-only writes are atomic at the line boundary —
/// a crash mid-write loses at most one entry, never corrupts the file.
@MainActor
@Observable
final class HistoryStore {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "History")

    /// File location. Public so diagnostics paths can reference it.
    /// `nonisolated` for the same reason as `AliasStore.fileURL` —
    /// the sidecar env builder is nonisolated and may want the path
    /// in future revisions.
    nonisolated static let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = base.appending(path: "Hark", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "history.jsonl")
    }()

    /// Cap on entries kept on disk. 1000 entries × ~200 bytes ≈ 200 KB,
    /// well under any reasonable concern, and weeks of normal dictation
    /// for a single user.
    static let maxEntries = 1000

    /// All known entries, newest-first. Loaded lazily on first access
    /// so app launch isn't blocked on file I/O.
    private(set) var entries: [HistoryEntry] = []

    /// File path injected for tests. Production passes the default.
    private let url: URL

    /// True after the first `load()` call so the lazy hydration in
    /// `record(_:)` doesn't re-read the file on every append.
    private var loaded = false

    init(url: URL = HistoryStore.fileURL) {
        self.url = url
    }

    /// Read the file into memory. Idempotent; no-op after the first
    /// successful call.
    func load() {
        guard !loaded else { return }
        loaded = true
        entries = Self.readEntries(from: url)
    }

    /// Persist a new entry. Loads on-demand if the store hasn't been
    /// initialized yet so the first dictation after launch doesn't
    /// need a separate `load()` call from the caller.
    func record(_ entry: HistoryEntry) {
        load()
        entries.insert(entry, at: 0)
        // Trim oldest tail entries past the cap. Done in-place so the
        // memory footprint matches what we'll write back to disk.
        if entries.count > Self.maxEntries {
            entries.removeLast(entries.count - Self.maxEntries)
        }
        Self.rewrite(entries, to: url)
    }

    /// Filter entries whose transcript / outcome contains `query`
    /// (case-insensitive). Empty query returns everything.
    func search(_ query: String) -> [HistoryEntry] {
        load()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !trimmed.isEmpty else { return entries }
        return entries.filter { entry in
            entry.matchableText.contains(trimmed)
        }
    }

    /// Erase all entries. Used by the Settings "Clear history" button.
    func clear() {
        entries.removeAll()
        try? FileManager.default.removeItem(at: url)
    }

    // MARK: - Persistence helpers

    /// Read the entire file, one JSON object per line. Skips malformed
    /// lines rather than throwing — a single bad write shouldn't
    /// destroy the whole history.
    static func readEntries(from url: URL) -> [HistoryEntry] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            guard let text = String(data: data, encoding: .utf8) else { return [] }
            let decoder = JSONDecoder()
            decoder.dateDecodingStrategy = .iso8601
            var parsed: [HistoryEntry] = []
            for line in text.split(whereSeparator: \.isNewline) {
                let lineData = Data(line.utf8)
                guard let entry = try? decoder.decode(HistoryEntry.self, from: lineData) else { continue }
                parsed.append(entry)
            }
            // File is append-order (oldest first); we return newest-first
            // because that's how the UI wants to render.
            return parsed.reversed()
        } catch {
            logger.error("Failed to read history: \(String(describing: error), privacy: .public)")
            return []
        }
    }

    /// Rewrite the entire file from the in-memory list. We could
    /// optimize to "append only" for the common case, but the rotated-
    /// trim path needs to rewrite anyway, and 200 KB ≪ disk write
    /// budget — simpler to always rewrite atomically.
    static func rewrite(_ entries: [HistoryEntry], to url: URL) {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        var buffer = Data()
        // Persist oldest-first to match the on-disk semantic ("file
        // grows over time"). `entries` is newest-first in memory.
        for entry in entries.reversed() {
            do {
                let line = try encoder.encode(entry)
                buffer.append(line)
                buffer.append(0x0A)
            } catch {
                let desc = String(describing: error)
                Self.logger.error("Skipped history entry on encode failure: \(desc, privacy: .public)")
            }
        }
        do {
            let tmp = url.appendingPathExtension("tmp")
            try buffer.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Self.logger.error("Failed to write history: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "History", "write failed: \(error)")
        }
    }
}

/// A single recorded transcript + its outcome.
///
/// `kind` tracks which pipeline branch produced this entry so the UI
/// can render the right icon and the re-run button can route through
/// the same trigger. `polished` is nil for command-mode entries (we
/// don't run polish on commands).
struct HistoryEntry: Identifiable, Codable, Equatable, Hashable {
    let id: UUID
    let timestamp: Date
    let kind: Kind
    /// Raw Whisper output as captured (after trimming).
    let transcript: String
    /// Cleaned-up form for dictate / insert entries. Nil for commands.
    let polished: String?
    /// Pill-facing summary — either the final transcript (dictate),
    /// the paste status (insert), or the command result (command).
    let summary: String
    /// True if the dispatch step reported success. Commands report
    /// `succeeded`; dictate/insert default to true because the
    /// transcript itself "succeeded" once Whisper produced it.
    let succeeded: Bool

    enum Kind: String, Codable, CaseIterable, Equatable {
        case dictate
        case insert
        case command

        var label: String {
            switch self {
            case .dictate: "Dictation"
            case .insert: "Insert"
            case .command: "Command"
            }
        }

        var symbol: String {
            switch self {
            case .dictate: "text.bubble"
            case .insert: "text.cursor"
            case .command: "wand.and.stars"
            }
        }
    }

    /// Concatenated text used by `HistoryStore.search`. Pre-lowercased
    /// so search is O(n) without per-iteration `.lowercased()` calls.
    var matchableText: String {
        var s = transcript.lowercased()
        if let polished {
            s += "\n"
            s += polished.lowercased()
        }
        s += "\n"
        s += summary.lowercased()
        return s
    }

    /// Convenience accessor for the "best" display string — polished
    /// when present (dictate/insert), otherwise the raw transcript.
    var displayText: String {
        polished ?? transcript
    }
}
