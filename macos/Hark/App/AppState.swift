import Foundation
import Observation

/// The single source of truth for app-wide observable UI state. Lives on the
/// main actor; everything in Hark that mutates UI flows through here so we can
/// keep imperative AppKit (NSPanel, NSStatusItem) and declarative SwiftUI views
/// in sync without duplicate ownership.
@MainActor
@Observable
final class AppState {
    /// Whether the floating panel should be visible. Toggling this is the only
    /// supported way to show or hide the panel — `PanelWindowController`
    /// observes the value and drives the underlying `NSPanel`.
    var isPanelVisible: Bool = false

    /// The most recent transcription, if any. Cleared when a new recording
    /// starts. The panel renders the transcript when this is non-nil and the
    /// recorder/transcriber are idle.
    var transcript: String?

    /// Whether the most recent transcription was attempted as a paste-into-
    /// input (Fn + Ctrl) but no focused text input was found. The pill shows
    /// a "no input focused" hint when this is true.
    var transcriptInsertFailed = false

    /// True while Claude is post-processing the raw Whisper output
    /// (punctuation / casing / filler cleanup). The pill renders a
    /// "Polishing" state instead of the final transcript.
    var isPolishing = false

    /// True while a voice command (`.command` trigger) is being executed
    /// by the Agent SDK. The pill renders "Executing…".
    var isExecutingCommand = false

    /// Latest voice-command outcome. The pill shows this for a few
    /// seconds after execution finishes, then clears.
    var commandResult: CommandResult?

    /// The result of a single executeCommand RPC.
    struct CommandResult: Equatable {
        let summary: String
        let succeeded: Bool
    }

    /// Cumulative Claude usage stats since first use. Persisted to
    /// UserDefaults; never reset by the app.
    var claudeUsage = ClaudeUsage.load()
}

/// Persistent Claude usage counters. Cumulative across launches.
struct ClaudeUsage: Codable, Equatable {
    var inputTokens: Int = 0
    var outputTokens: Int = 0
    var cacheReadTokens: Int = 0
    var cacheCreationTokens: Int = 0
    var requestCount: Int = 0
    var lastUsedAt: Date?

    var totalTokens: Int {
        inputTokens + outputTokens + cacheReadTokens + cacheCreationTokens
    }

    private static let defaultsKey = "co.milbo.hark.claudeUsage"

    static func load() -> Self {
        guard
            let data = UserDefaults.standard.data(forKey: defaultsKey),
            let decoded = try? JSONDecoder().decode(Self.self, from: data) else
        {
            return Self()
        }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.defaultsKey)
    }

    mutating func add(input: Int, output: Int, cacheRead: Int, cacheCreation: Int) {
        inputTokens += input
        outputTokens += output
        cacheReadTokens += cacheRead
        cacheCreationTokens += cacheCreation
        requestCount += 1
        lastUsedAt = Date()
    }
}
