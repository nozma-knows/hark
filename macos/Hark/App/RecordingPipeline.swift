import Foundation
import OSLog

/// Post-recording delivery pipeline. Given a finalized transcript and the
/// trigger that captured it, routes to the right downstream action:
///
///   - `.command` → execute via the sidecar's Agent path; surface the
///     result in the command pill with auto-clear timing.
///   - `.dictate` / `.insert` → polish via the sidecar, then either show
///     the transcript or paste into the focused input.
///
/// Owns nothing about audio capture or hotkey state — pure consumer of a
/// finalized transcript string. Extracted from RecordingOrchestrator so
/// the state machine (start / stop / latch / cancel) stays separate from
/// the side-effect-heavy delivery logic. Each file ends up roughly half
/// the size and tested independently via the existing pipeline tests.
@MainActor
struct RecordingPipeline {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Pipeline")

    let appState: AppState
    let sidecar: any SidecarRequesting
    /// Per-app polish profile selector. The pipeline asks the store for
    /// the profile that applies to the frontmost app at finalize time —
    /// keeps the routing single-source-of-truth even though the store is
    /// edited from a separate Settings pane.
    let polishProfileStore: PolishProfileStore
    /// Append-only record of every transcript Hark has produced. Optional
    /// at the type level so headless tests can omit it; production
    /// always wires the singleton.
    let historyStore: HistoryStore?

    // MARK: - Entry

    /// Dispatch by trigger. Pure routing — the concrete work happens in
    /// `executeVoiceCommand` (command) and `polishAndDeliver` (dictate/
    /// insert). Both reset their respective `appState` flags via `defer`,
    /// so an early throw can't leave the pill stuck in "Polishing" or
    /// "Executing" forever.
    func deliver(_ transcript: String, trigger: HotkeyTrigger) async {
        switch trigger {
        case .command:
            await executeVoiceCommand(transcript)
        case .dictate, .insert:
            await polishAndDeliver(transcript, trigger: trigger)
        }
    }

    // MARK: - Polish + deliver (dictate / insert)

    private func polishAndDeliver(_ raw: String, trigger: HotkeyTrigger) async {
        // Sample the frontmost bundle BEFORE we start polishing — Hark
        // becoming key (the pill activates briefly, or focus shifts) would
        // otherwise change `frontmostApplication` mid-call. Reading here
        // pins the profile to where the user was when they spoke.
        let profile = polishProfileStore.currentProfile()
        appState.isPolishing = true
        let text = await polishOrFallback(raw, profile: profile)
        appState.isPolishing = false

        let kind: HistoryEntry.Kind
        if trigger == .insert {
            let hasInput = InputInserter.hasFocusedTextInput()
            Self.logger.info("Insert mode: hasFocusedInput=\(hasInput, privacy: .public)")
            if hasInput {
                InputInserter.paste(text)
                kind = .insert
            } else {
                appState.transcript = text
                appState.transcriptInsertFailed = true
                kind = .dictate
            }
        } else {
            appState.transcript = text
            kind = .dictate
        }

        historyStore?.record(
            HistoryEntry(
                id: UUID(),
                timestamp: Date(),
                kind: kind,
                transcript: raw,
                polished: text,
                summary: text,
                succeeded: true
            )
        )
    }

    /// Send the trimmed Whisper output to Claude (via the Bun sidecar) for
    /// punctuation / casing / filler cleanup. Returns the polished string,
    /// or the raw input unchanged on any failure. Side-effect: accumulates
    /// usage stats into `appState.claudeUsage` (persisted).
    ///
    /// The `profile` argument routes the sidecar to one of the per-tone
    /// system prompts (casual / formal / code / standard). Unknown
    /// profile names fall back to `standard` on the sidecar side.
    private func polishOrFallback(_ raw: String, profile: PolishProfile) async -> String {
        struct Params: Encodable {
            let text: String
            let profile: String
        }
        struct PolishResult: Decodable {
            let polished: String
            let changed: Bool
            let usage: SidecarUsage?
        }
        do {
            let result: PolishResult = try await sidecar.request(
                method: "polishTranscript",
                params: Params(text: raw, profile: profile.rawValue),
                result: PolishResult.self,
                timeout: 8
            )
            recordUsage(result.usage)
            return result.polished
        } catch {
            Self.logger.error("Polish failed (using raw): \(String(describing: error), privacy: .public)")
            return raw
        }
    }

    // MARK: - Execute (command)

    /// Send the transcript to the Agent SDK in the sidecar; it drives Bash
    /// to perform a macOS action (open app, run AppleScript, run Shortcut).
    /// Shows live state in the pill (isExecutingCommand → commandResult).
    private func executeVoiceCommand(_ transcript: String) async {
        struct Params: Encodable { let transcript: String }
        struct CommandResultPayload: Decodable {
            let summary: String
            let succeeded: Bool
            let usage: SidecarUsage?
        }

        appState.isExecutingCommand = true
        defer { appState.isExecutingCommand = false }

        do {
            // Voice commands can run interactive Claude sessions (read files,
            // plan, execute Bash). 60s gives Claude room to think without
            // leaving the user staring at "Executing…" forever.
            let result: CommandResultPayload = try await sidecar.request(
                method: "executeCommand",
                params: Params(transcript: transcript),
                result: CommandResultPayload.self,
                timeout: 60
            )
            recordUsage(result.usage)
            appState.commandResult = .init(summary: result.summary, succeeded: result.succeeded)
            scheduleCommandResultClear(result.summary)
            historyStore?.record(
                HistoryEntry(
                    id: UUID(),
                    timestamp: Date(),
                    kind: .command,
                    transcript: transcript,
                    polished: nil,
                    summary: result.summary,
                    succeeded: result.succeeded
                )
            )
        } catch {
            Self.logger.error("executeCommand failed: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "Orchestrator", "executeCommand failed: \(error)")
            let failureSummary = "Command failed: \(error.localizedDescription)"
            appState.commandResult = .init(
                summary: failureSummary,
                succeeded: false
            )
            historyStore?.record(
                HistoryEntry(
                    id: UUID(),
                    timestamp: Date(),
                    kind: .command,
                    transcript: transcript,
                    polished: nil,
                    summary: failureSummary,
                    succeeded: false
                )
            )
        }
    }

    // MARK: - Failure surfacing (shared between paths)

    /// Render a finalize-level error (transcribe failure, model not loaded)
    /// in the command-result pill so the user knows their dictation didn't
    /// silently vanish. Called from RecordingOrchestrator when the transcribe
    /// step throws before any path-specific work has begun.
    func surfaceTranscribeError(_ error: Error) {
        appState.isPolishing = false
        appState.isExecutingCommand = false
        Self.logger.error("Transcribe failed: \(String(describing: error), privacy: .public)")
        FileLogger.shared.log(.error, category: "Orchestrator", "finalize failed: \(error)")
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Transcription failed."
        appState.commandResult = .init(summary: message, succeeded: false)
        scheduleCommandResultClear(message)
    }

    // MARK: - Shared helpers

    /// Token usage block returned by every Claude-backed sidecar method.
    /// Both `polishTranscript` and `executeCommand` include this when the
    /// underlying Claude call succeeded, so we model it once and decode
    /// the same shape both places.
    struct SidecarUsage: Decodable {
        let inputTokens: Int?
        let outputTokens: Int?
        let cacheReadTokens: Int?
        let cacheCreationTokens: Int?
    }

    /// Accumulate a single Claude call's usage into the persisted running
    /// totals on `appState.claudeUsage`. Nil-safe: a sidecar that omits
    /// the usage block (or returns nil fields) contributes zero to each
    /// counter, so the call is still counted but doesn't skew totals.
    private func recordUsage(_ usage: SidecarUsage?) {
        var stats = appState.claudeUsage
        stats.add(
            input: usage?.inputTokens ?? 0,
            output: usage?.outputTokens ?? 0,
            cacheRead: usage?.cacheReadTokens ?? 0,
            cacheCreation: usage?.cacheCreationTokens ?? 0
        )
        stats.save()
        appState.claudeUsage = stats
    }

    /// Auto-clear the command-result pill after a few seconds so the pill
    /// returns to idle without the user dismissing.
    private func scheduleCommandResultClear(_ summary: String) {
        Task { [appState] in
            try? await Task.sleep(for: .seconds(5))
            if appState.commandResult?.summary == summary {
                appState.commandResult = nil
            }
        }
    }
}
