import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "AppDelegate")

    let appState: AppState
    let permissions: PermissionsManager
    let hotkey: HotkeyManager
    let recorder: AudioRecorder
    let transcriber: Transcriber
    let claudeAuth: ClaudeAuth
    let sidecar: AgentSidecar
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        let hotkeyManager = HotkeyManager()
        let audioRecorder = AudioRecorder()
        let transcriberInstance = Transcriber()
        let claudeAuthInstance = ClaudeAuth()
        let sidecarInstance = AgentSidecar(
            environmentProvider: { [claudeAuthInstance] in
                claudeAuthInstance.sidecarEnvironment()
            }
        )
        appState = state
        permissions = perms
        hotkey = hotkeyManager
        recorder = audioRecorder
        transcriber = transcriberInstance
        claudeAuth = claudeAuthInstance
        sidecar = sidecarInstance
        panelController = PanelWindowController(
            appState: state,
            recorder: audioRecorder,
            transcriber: transcriberInstance
        )
        onboardingController = OnboardingWindowController(
            permissions: perms,
            claudeAuth: claudeAuthInstance
        )
        super.init()

        hotkey.onKeyDown = { [weak self] trigger in self?.handleHotkeyDown(trigger) }
        hotkey.onKeyUp = { [weak self] trigger in self?.handleHotkeyUp(trigger) }
    }

    @ObservationIgnored private var activeTrigger: HotkeyTrigger = .dictate

    func applicationDidFinishLaunching(_: Notification) {
        // Hark is a regular dock app (Wispr Flow-style). LSUIElement is
        // false in Info.plist so the icon shows up in the Dock.
        NSApp.setActivationPolicy(.regular)

        // Pill UI is visible from launch — Wispr Flow-style always-on
        // bottom-center indicator.
        panelController.showAlways()

        NotificationCenter.default.addObserver(
            forName: NSApplication.didBecomeActiveNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            // Permissions and Claude auth can flip silently while the user is
            // in System Settings / Terminal; re-poll on foreground return.
            MainActor.assumeIsolated {
                self?.permissions.refresh()
                self?.claudeAuth.refresh()
            }
        }

        onboardingController.showIfNeeded()

        // Warm the previously selected model in the background so the first
        // dictation doesn't pay the load cost. If the model isn't downloaded
        // yet, this kicks off the download in parallel.
        transcriber.bootstrap()
    }

    // MARK: - Hotkey state machine

    private func handleHotkeyDown(_ trigger: HotkeyTrigger) {
        guard ensureReady() else { return }
        switch hotkey.mode {
        case .hold:
            startRecording(trigger: trigger)
        case .toggle:
            if recorder.state == .recording {
                stopRecording()
            } else {
                startRecording(trigger: trigger)
            }
        }
    }

    private func handleHotkeyUp(_: HotkeyTrigger) {
        guard hotkey.mode == .hold, recorder.state == .recording else { return }
        stopRecording()
    }

    private func startRecording(trigger: HotkeyTrigger) {
        activeTrigger = trigger
        appState.transcript = nil
        appState.transcriptInsertFailed = false
        do {
            try recorder.start()
        } catch {
            Self.logger.error("Failed to start recording: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopRecording() {
        let samples = recorder.stop()
        guard !samples.isEmpty else { return }
        let trigger = activeTrigger
        Task { [weak self] in
            await self?.finalizeTranscript(samples, trigger: trigger)
        }
    }

    private func finalizeTranscript(_ samples: [Float], trigger: HotkeyTrigger) async {
        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { return }

            switch trigger {
            case .dictate:
                appState.transcript = text
            case .insert:
                if InputInserter.hasFocusedTextInput() {
                    InputInserter.paste(text)
                    // Don't surface a panel — the text landed where the
                    // user was already typing.
                } else {
                    appState.transcript = text
                    appState.transcriptInsertFailed = true
                }
            }
        } catch {
            Self.logger.error("Transcribe failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Common precondition for any action that needs mic + accessibility.
    /// Routes to onboarding if anything's missing and returns false.
    private func ensureReady() -> Bool {
        permissions.refresh()
        guard permissions.allGranted else {
            onboardingController.show()
            return false
        }
        return true
    }
}
