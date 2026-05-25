import AppKit
import Foundation
import Observation
import OSLog

/// A polish style applied to dictated text before it lands in the pill
/// or the focused input. The default ("polish") preserves the meaning
/// of the dictation with light punctuation/casing fixes; other profiles
/// adjust the tone to match where the text will land.
///
/// Identifiers are stable strings the sidecar maps to system prompts.
/// Adding a new profile is a two-step change:
///   1. Add a case here + a `displayName` + a `description`.
///   2. Add the matching prompt branch in `Sidecar/src/polishTranscript.ts`.
///
/// Built into the enum (not user-defined) so we can rely on the sidecar
/// honoring exactly the set we ship — letting users write arbitrary
/// prompts would create a different feature shape entirely.
enum PolishProfile: String, CaseIterable, Identifiable, Codable, Equatable {
    /// Default behavior: punctuation + casing + filler removal, no
    /// stylistic shifts. Matches Hark's pre-profile behavior.
    case standard

    /// Conversational tone — used for Slack, Discord, iMessage etc.
    /// Keeps contractions, allows short fragments, drops formal
    /// connectives. Doesn't add emoji.
    case casual

    /// Email / Notes / docs tone — full sentences, formal connectives,
    /// expands contractions where natural.
    case formal

    /// Code-adjacent tone — used for IDE comments, commit messages,
    /// terminal prompts. Preserves technical terms, monospaced
    /// identifiers, and shell-y verbs ("rm", "grep") exactly.
    case code

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .standard: "Standard"
        case .casual: "Casual"
        case .formal: "Formal"
        case .code: "Code / Terminal"
        }
    }

    var description: String {
        switch self {
        case .standard: "Light polish — punctuation, casing, fillers only."
        case .casual: "Shorter, contractions kept. Slack / iMessage feel."
        case .formal: "Complete sentences, expanded contractions. Email / docs."
        case .code: "Preserves technical terms verbatim. IDEs / Terminal."
        }
    }

    static let `default`: PolishProfile = .standard
}

/// Persistent mapping `bundleID → PolishProfile`. Stored in UserDefaults
/// because the dataset is tiny (one row per app) and we want it readable
/// in support bundles without a separate file.
@MainActor
@Observable
final class PolishProfileStore {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "PolishProfile")
    private static let defaultsKey = "co.milbo.hark.polishProfiles"

    /// User-configured override per bundle ID. App lookups fall back
    /// to `defaultProfile` when no entry exists.
    private(set) var overrides: [String: PolishProfile] = [:]

    /// Profile used for any app without a specific override.
    private(set) var defaultProfile: PolishProfile = .standard

    init() {
        load()
    }

    /// Profile that should be applied to text destined for the given
    /// app bundle ID. Nil bundle ID (no frontmost app, headless test)
    /// hits the default branch.
    func profile(forBundleID bundleID: String?) -> PolishProfile {
        guard let bundleID, !bundleID.isEmpty else { return defaultProfile }
        return overrides[bundleID] ?? defaultProfile
    }

    /// Convenience: profile for the system's frontmost application.
    /// Wraps the NSWorkspace lookup so callers don't have to know
    /// about AppKit. Pure pass-through.
    func currentProfile() -> PolishProfile {
        profile(forBundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
    }

    /// Set the override for the given bundle ID. Passing `nil`
    /// removes the override (the bundle falls back to default).
    func setOverride(_ profile: PolishProfile?, for bundleID: String) {
        let trimmed = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let profile {
            overrides[trimmed] = profile
        } else {
            overrides.removeValue(forKey: trimmed)
        }
        persist()
    }

    /// Swap the fallback profile.
    func setDefault(_ profile: PolishProfile) {
        defaultProfile = profile
        persist()
    }

    /// Sorted list of `(bundleID, profile)` for the UI.
    var sortedOverrides: [(bundleID: String, profile: PolishProfile)] {
        overrides.sorted { $0.key < $1.key }.map { ($0.key, $0.value) }
    }

    // MARK: - Persistence

    private struct Storage: Codable {
        var defaultProfile: String
        var overrides: [String: String]
    }

    private func load() {
        guard let data = UserDefaults.standard.data(forKey: Self.defaultsKey) else { return }
        do {
            let storage = try JSONDecoder().decode(Storage.self, from: data)
            defaultProfile = PolishProfile(rawValue: storage.defaultProfile) ?? .standard
            overrides = storage.overrides.compactMapValues(PolishProfile.init(rawValue:))
        } catch {
            Self.logger.error("Failed to decode polish profiles: \(String(describing: error), privacy: .public)")
        }
    }

    private func persist() {
        let storage = Storage(
            defaultProfile: defaultProfile.rawValue,
            overrides: overrides.mapValues(\.rawValue)
        )
        do {
            let data = try JSONEncoder().encode(storage)
            UserDefaults.standard.set(data, forKey: Self.defaultsKey)
        } catch {
            Self.logger.error("Failed to encode polish profiles: \(String(describing: error), privacy: .public)")
        }
    }
}
