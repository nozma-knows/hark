import Foundation
import Observation
import OSLog

/// User-defined voice command aliases.
///
/// One alias = one trigger phrase + a sequence of shell commands. When the
/// user dictates exactly the phrase, the sidecar's `alias` dispatcher
/// (priority 0, runs first) executes the commands in order via bash.
///
/// Persisted as a JSON file at `~/Library/Application Support/Hark/aliases.json`
/// so the sidecar can read it without an IPC round-trip. The file is the
/// single source of truth — `AliasStore` owns the read/write surface,
/// the SettingsUI binds to `@Observable` `aliases`, and the sidecar
/// rebuilds its in-memory cache when the file's mtime changes.
@MainActor
@Observable
final class AliasStore {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "AliasStore")

    /// Canonical location of the aliases file. Public so the sidecar
    /// env builder can point `HARK_ALIASES_PATH` at the same path.
    /// `nonisolated` because callers from outside MainActor (the
    /// sidecar env builder is `nonisolated static`) need access; the
    /// closure body is pure FileManager + URL math so no actor hop
    /// is required.
    nonisolated static let fileURL: URL = {
        let fm = FileManager.default
        let base = fm.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appending(path: "Library/Application Support")
        let dir = base.appending(path: "Hark", directoryHint: .isDirectory)
        try? fm.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appending(path: "aliases.json")
    }()

    /// Schema version. Bumped only when the on-disk shape changes in
    /// a way the sidecar's `sanitize()` can't read forward-compatibly.
    nonisolated static let schemaVersion = 1

    /// Currently configured aliases, sorted by phrase for stable UI.
    private(set) var aliases: [Alias] = []

    /// The file URL this store reads from / writes to. Injectable so
    /// tests can point at a tmp file without monkey-patching the
    /// process's Application Support path.
    private let url: URL

    init(url: URL = AliasStore.fileURL) {
        self.url = url
        reload()
    }

    /// Read the on-disk file and replace `aliases`. Idempotent: a
    /// missing file leaves `aliases == []`, a malformed file does the
    /// same after logging — never throws.
    func reload() {
        aliases = Self.read(from: url)
    }

    /// Add a new alias. Phrase is trimmed + lowercased so the match
    /// between sidecar and settings UI is exact, and commands are
    /// sanitized (whitespace-only entries dropped).
    @discardableResult
    func add(phrase: String, commands: [String]) -> Alias? {
        guard let alias = Alias.make(id: UUID(), phrase: phrase, commands: commands) else {
            return nil
        }
        aliases.append(alias)
        sortAndPersist()
        return alias
    }

    /// Replace an existing alias by id. Returns false on miss or
    /// invalid phrase / commands (UI-side prevents this, but file
    /// edits could land us here).
    @discardableResult
    func update(_ updated: Alias) -> Bool {
        guard let index = aliases.firstIndex(where: { $0.id == updated.id }) else { return false }
        guard let cleaned = Alias.make(id: updated.id, phrase: updated.phrase, commands: updated.commands) else {
            return false
        }
        aliases[index] = cleaned
        sortAndPersist()
        return true
    }

    /// Delete by id. No-op on miss.
    func delete(id: UUID) {
        aliases.removeAll { $0.id == id }
        sortAndPersist()
    }

    // MARK: - Persistence

    private func sortAndPersist() {
        aliases.sort { $0.phrase < $1.phrase }
        Self.write(aliases, to: url)
    }

    /// Deserialize the file at `url` into a list of aliases. Returns
    /// `[]` on any failure path; logs to the file log so a corrupted
    /// file is still diagnosable from a user-submitted bundle.
    static func read(from url: URL) -> [Alias] {
        guard FileManager.default.fileExists(atPath: url.path) else { return [] }
        do {
            let data = try Data(contentsOf: url)
            let decoded = try JSONDecoder().decode(FileSchema.self, from: data)
            return decoded.aliases.compactMap { entry in
                guard let parsedId = UUID(uuidString: entry.id) else { return nil }
                return Alias.make(id: parsedId, phrase: entry.phrase, commands: entry.commands)
            }
        } catch {
            logger.error("Failed to read aliases: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "AliasStore", "read failed: \(error)")
            return []
        }
    }

    /// Atomically write the alias list. Writes to a sibling tmp file
    /// then renames, so a crash mid-write can't leave a half-written
    /// JSON file the sidecar would refuse to load.
    static func write(_ aliases: [Alias], to url: URL) {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let payload = FileSchema(
            version: schemaVersion,
            aliases: aliases.map { FileSchema.Entry(id: $0.id.uuidString, phrase: $0.phrase, commands: $0.commands) }
        )
        do {
            let data = try encoder.encode(payload)
            let tmp = url.appendingPathExtension("tmp")
            try data.write(to: tmp, options: .atomic)
            _ = try FileManager.default.replaceItemAt(url, withItemAt: tmp)
        } catch {
            Self.logger.error("Failed to write aliases: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "AliasStore", "write failed: \(error)")
        }
    }

    // MARK: - On-disk schema

    /// File envelope. Codable directly into the sidecar's expected
    /// shape — keep both sides in lockstep when changing fields.
    struct FileSchema: Codable, Equatable {
        let version: Int
        let aliases: [Entry]

        struct Entry: Codable, Equatable {
            let id: String
            let phrase: String
            let commands: [String]
        }
    }
}

/// A single user-defined alias. Equatable so SwiftUI list re-render
/// diffs are O(n); Identifiable so ForEach keys rows by stable UUID.
struct Alias: Identifiable, Equatable, Hashable {
    let id: UUID
    var phrase: String
    var commands: [String]

    /// Validating factory: trims + lowercases the phrase, drops empty
    /// commands. Returns nil if the result wouldn't be a usable alias
    /// (empty phrase or zero commands). The store funnels every
    /// add/update through here so on-disk + in-memory shapes match.
    static func make(id: UUID, phrase: String, commands: [String]) -> Self? {
        let cleanPhrase = phrase.lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
        guard !cleanPhrase.isEmpty else { return nil }
        let cleanCommands = commands
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !cleanCommands.isEmpty else { return nil }
        return Self(id: id, phrase: cleanPhrase, commands: cleanCommands)
    }
}
