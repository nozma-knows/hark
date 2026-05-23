import AppKit
import Foundation
import OSLog

/// Owns the recording → transcribe → deliver pipeline's STATE MACHINE.
/// Splits this logic out of AppDelegate so the transitions can be reasoned
/// about (and unit-tested) independently of the AppKit lifecycle.
///
/// Post-transcribe delivery (polish + paste + executeCommand sidecar
/// roundtrips) lives in `RecordingPipeline` — this file is intentionally
/// focused on:
///   - start / stop transitions across the hotkey + pill entry points
///   - the manual-trigger latch that distinguishes pill-initiated
///     recordings from hotkey ones
///   - permission gating
///   - dispatching to the pipeline once transcribe yields a string
///
/// Inputs (events from the rest of the app):
///   - `handleHotkeyDown(_:)` / `handleHotkeyUp(_:)` — the global Fn tap
///   - `togglePanelRecording(_:)` — the pill's record button / chevron menu
///   - `cancelProcessing()` — the X on the processing pill
@MainActor
final class RecordingOrchestrator {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Orchestrator")

    private let appState: AppState
    private let hotkey: any HotkeyState
    private let recorder: any AudioRecording
    private let transcriber: any Transcribing
    private let pipeline: RecordingPipeline
    private let permissions: any PermissionGate
    private let needsOnboarding: () -> Void

    /// The trigger captured at session start. For hotkey-driven sessions
    /// this is the LIVE modifier state at Fn-up time (so the user can
    /// add/remove Shift/Ctrl mid-hold and the gesture matches what they
    /// released). For pill-initiated sessions this is the trigger the
    /// user explicitly picked from the chevron menu.
    @ObservationIgnored private var activeTrigger: HotkeyTrigger = .dictate

    /// Non-nil when the recording was started from the pill UI rather than
    /// the global hotkey. Read at stop to know which trigger to finalize
    /// with — and to lock out hotkey-up from stopping a pill recording
    /// (the user must click the record button to end it).
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
        pipeline = RecordingPipeline(appState: appState, sidecar: sidecar)
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

    // MARK: - Transcribe → dispatch

    /// Transcribe the captured samples, then hand the trimmed string to
    /// `pipeline.deliver(_:trigger:)`. Failures surface through the
    /// pipeline's `surfaceTranscribeError` so the user sees a real error
    /// pill instead of a silent return to idle.
    private func finalize(_ samples: [Float], trigger: HotkeyTrigger) async {
        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }
            await pipeline.deliver(trimmed, trigger: trigger)
        } catch {
            pipeline.surfaceTranscribeError(error)
        }
    }

    // MARK: - Helpers

    private func ensureReady() -> Bool {
        permissions.refresh()
        guard permissions.allGranted else {
            needsOnboarding()
            return false
        }
        return true
    }
}
