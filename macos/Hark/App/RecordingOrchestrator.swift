import AppKit
import Foundation
import OSLog

/// Owns the recording → transcribe → deliver pipeline. Splits this logic out
/// of AppDelegate so the state machine can be reasoned about (and unit-tested)
/// independently of the AppKit lifecycle.
///
/// Inputs (events from the rest of the app):
///   - `handleHotkeyDown(_:)` / `handleHotkeyUp(_:)` — the global Fn tap
///   - `togglePanelRecording(_:)` — the pill's record button / chevron menu
///   - `cancelProcessing()` — the X on the processing pill
///
/// Side-effects (it mutates):
///   - `recorder` (start / stop)
///   - `appState` (transcript, isPolishing, isExecutingCommand, commandResult,
///     claudeUsage)
///   - `transcriber` (transcribe / cancel)
///
/// The pipeline branches at `finalize()` on the active trigger:
///   - `.command` → executeVoiceCommand (no polish; Claude reads intent
///     straight from the raw transcript)
///   - `.dictate` → polish, then show in pill
///   - `.insert` → polish, then paste into focused input (or fall back to pill
///     with a warning)
@MainActor
final class RecordingOrchestrator {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Orchestrator")

    private let appState: AppState
    private let hotkey: any HotkeyState
    private let recorder: any AudioRecording
    private let transcriber: any Transcribing
    private let sidecar: any SidecarRequesting
    private let permissions: any PermissionGate
    private let needsOnboarding: () -> Void

    /// The trigger captured at session start. For hotkey-driven sessions
    /// this is the LIVE modifier state at Fn-up time (so the user can
    /// add/remove Shift/Ctrl mid-hold and the gesture matches what they
    /// released). For pill-initiated sessions this is the trigger the
    /// user explicitly picked from the chevron menu.
    ///
    /// Threading: `MainActor` confined by the enclosing class isolation.
    /// All reads/writes happen from `handleHotkeyDown`, `handleHotkeyUp`,
    /// or `togglePanelRecording`, each of which is a MainActor method on
    /// `RecordingOrchestrator`. No actor hop needed.
    @ObservationIgnored private var activeTrigger: HotkeyTrigger = .dictate

    /// Non-nil when the recording was started from the pill UI rather than
    /// the global hotkey. Read at stop to know which trigger to finalize
    /// with — and to lock out hotkey-up from stopping a pill recording
    /// (the user must click the record button to end it).
    ///
    /// Threading: same `MainActor` confinement as `activeTrigger`. The
    /// `finalize(_:trigger:)` continuation reads `manualRecordingTrigger`
    /// transitively through the trigger argument that `stop()` passes in
    /// — by then we've already cleared the latch on MainActor, so even
    /// the async `finalize` Task only reads the captured `trigger` local,
    /// not the ivar.
    @ObservationIgnored private var manualRecordingTrigger: HotkeyTrigger?

    init(
        appState: AppState,
        hotkey: any HotkeyState,
        recorder: any AudioRecording,
        transcriber: any Transcribing,
        sidecar: any SidecarRequesting,
        permissions: any PermissionGate,
        needsOnboarding: @escaping () -> Void
    ) {
        self.appState = appState
        self.hotkey = hotkey
        self.recorder = recorder
        self.transcriber = transcriber
        self.sidecar = sidecar
        self.permissions = permissions
        self.needsOnboarding = needsOnboarding
    }

    // MARK: - Public entry points

    func handleHotkeyDown(_ trigger: HotkeyTrigger) {
        guard ensureReady() else { return }
        // Any Fn-press while a recording is in progress stops it — regardless
        // of whether the recording was started via hotkey or pill click, and
        // regardless of hold/toggle mode. Without this branch, HOLD mode tries
        // to start a SECOND recording (which silently fails inside
        // AudioRecorder) and the existing one becomes unstoppable from the
        // keyboard.
        if recorder.state == .recording {
            stop()
            return
        }
        start(trigger: trigger, manual: false)
    }

    func handleHotkeyUp(_: HotkeyTrigger) {
        guard hotkey.mode == .hold, recorder.state == .recording else { return }
        // Don't stop a recording the pill explicitly started — the user must
        // click the record button to end it.
        guard manualRecordingTrigger == nil else { return }
        stop()
    }

    /// Pill UI entry point: click-to-toggle recording. The selected mode
    /// (.dictate / .insert / .command) is preserved through the finalize
    /// step, regardless of which Fn modifiers happen to be down.
    func togglePanelRecording(_ trigger: HotkeyTrigger) {
        guard ensureReady() else { return }
        if recorder.state == .recording {
            stop()
        } else {
            start(trigger: trigger, manual: true)
        }
    }

    /// Force-cancel whatever post-recording step is in flight (transcribe
    /// or polish or execute). Wired to the X on the processing pill.
    func cancelProcessing() {
        Self.logger.info("User requested cancel of in-flight processing")
        FileLogger.shared.log(.info, category: "Orchestrator", "user cancelled processing")
        transcriber.cancelInFlight()
        appState.isPolishing = false
        appState.isExecutingCommand = false
        manualRecordingTrigger = nil
    }

    // MARK: - State transitions

    private func start(trigger: HotkeyTrigger, manual: Bool) {
        activeTrigger = trigger
        manualRecordingTrigger = manual ? trigger : nil
        appState.transcript = nil
        appState.transcriptInsertFailed = false
        do {
            try recorder.start()
            FileLogger.shared.log(
                .info,
                category: "Orchestrator",
                "record start trigger=\(trigger) manual=\(manual)"
            )
        } catch {
            Self.logger.error("Failed to start recording: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "Orchestrator", "record start failed: \(error)")
        }
    }

    private func stop() {
        let samples = recorder.stop()
        guard !samples.isEmpty else { return }
        // For pill-initiated recordings, use the trigger that was selected at
        // start (the user explicitly chose Execute / Fill input / dictate via
        // the UI). For hotkey-driven recordings, use the LIVE trigger at
        // release time — lets the user add/remove Ctrl mid-press and the
        // resulting action matches what they were holding when they let go.
        let trigger = manualRecordingTrigger ?? hotkey.currentTrigger
        manualRecordingTrigger = nil
        Self.logger.info("stop with trigger: \(String(describing: trigger), privacy: .public)")
        FileLogger.shared.log(
            .info,
            category: "Orchestrator",
            "record stop samples=\(samples.count) trigger=\(trigger)"
        )
        Task { [weak self] in
            await self?.finalize(samples, trigger: trigger)
        }
    }

    // MARK: - Pipeline

    private func finalize(_ samples: [Float], trigger: HotkeyTrigger) async {
        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            switch trigger {
            case .command:
                await executeVoiceCommand(trimmed)
            case .dictate, .insert:
                await polishAndDeliver(trimmed, trigger: trigger)
            }
        } catch {
            handleFinalizeError(error)
        }
    }

    private func polishAndDeliver(_ raw: String, trigger: HotkeyTrigger) async {
        appState.isPolishing = true
        let text = await polishOrFallback(raw)
        appState.isPolishing = false

        if trigger == .insert {
            let hasInput = InputInserter.hasFocusedTextInput()
            Self.logger.info("Insert mode: hasFocusedInput=\(hasInput, privacy: .public)")
            if hasInput {
                InputInserter.paste(text)
            } else {
                appState.transcript = text
                appState.transcriptInsertFailed = true
            }
        } else {
            appState.transcript = text
        }
    }

    private func handleFinalizeError(_ error: Error) {
        appState.isPolishing = false
        appState.isExecutingCommand = false
        Self.logger.error("Transcribe failed: \(String(describing: error), privacy: .public)")
        FileLogger.shared.log(.error, category: "Orchestrator", "finalize failed: \(error)")
        // Surface the failure to the user via the command-result pill —
        // otherwise the pill silently snaps back to idle and the user has
        // no idea why their dictation vanished.
        let message = (error as? LocalizedError)?.errorDescription
            ?? "Transcription failed."
        appState.commandResult = .init(summary: message, succeeded: false)
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(4))
            guard let self else { return }
            if appState.commandResult?.summary == message {
                appState.commandResult = nil
            }
        }
    }

    /// Send the transcript to the Agent SDK in the sidecar; it drives Bash
    /// to perform a macOS action (open app, run AppleScript, run Shortcut).
    /// Shows live state in the pill (isExecutingCommand → commandResult).
    private func executeVoiceCommand(_ transcript: String) async {
        struct Params: Encodable { let transcript: String }
        struct Result: Decodable {
            let summary: String
            let succeeded: Bool
            let usage: SidecarUsage?
        }

        appState.isExecutingCommand = true
        defer { appState.isExecutingCommand = false }

        do {
            // Voice commands can run interactive Claude sessions (read
            // files, plan, execute Bash). 60s gives Claude room to think
            // without leaving the user staring at "Executing…" forever.
            let result: Result = try await sidecar.request(
                method: "executeCommand",
                params: Params(transcript: transcript),
                result: Result.self,
                timeout: 60
            )
            recordUsage(result.usage)
            appState.commandResult = .init(summary: result.summary, succeeded: result.succeeded)
            scheduleCommandResultClear(result.summary)
        } catch {
            Self.logger.error("executeCommand failed: \(String(describing: error), privacy: .public)")
            FileLogger.shared.log(.error, category: "Orchestrator", "executeCommand failed: \(error)")
            appState.commandResult = .init(
                summary: "Command failed: \(error.localizedDescription)",
                succeeded: false
            )
        }
    }

    /// Send the trimmed Whisper output to Claude (via the Bun sidecar) for
    /// punctuation / casing / filler cleanup. Returns the polished string,
    /// or the raw input unchanged on any failure. Side-effect: accumulates
    /// usage stats into `appState.claudeUsage` (persisted).
    private func polishOrFallback(_ raw: String) async -> String {
        struct Params: Encodable { let text: String }
        struct Result: Decodable {
            let polished: String
            let changed: Bool
            let usage: SidecarUsage?
        }
        do {
            let result: Result = try await sidecar.request(
                method: "polishTranscript",
                params: Params(text: raw),
                result: Result.self,
                timeout: 8
            )
            recordUsage(result.usage)
            return result.polished
        } catch {
            Self.logger.error("Polish failed (using raw): \(String(describing: error), privacy: .public)")
            return raw
        }
    }

    // MARK: - Helpers

    /// Token usage block returned by every Claude-backed sidecar method.
    /// Both `polishTranscript` and `executeCommand` include this when the
    /// underlying Claude call succeeded, so we model it once and decode
    /// the same shape both places.
    private struct SidecarUsage: Decodable {
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
    /// returns to its idle state without the user dismissing.
    private func scheduleCommandResultClear(_ summary: String) {
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(5))
            guard let self else { return }
            if appState.commandResult?.summary == summary {
                appState.commandResult = nil
            }
        }
    }

    private func ensureReady() -> Bool {
        permissions.refresh()
        guard permissions.allGranted else {
            needsOnboarding()
            return false
        }
        return true
    }
}
