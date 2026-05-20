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
        onboardingController = OnboardingWindowController(permissions: perms)
        super.init()

        hotkey.onKeyDown = { [weak self] in self?.handleHotkeyDown() }
        hotkey.onKeyUp = { [weak self] in self?.handleHotkeyUp() }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // LSUIElement in Info.plist already runs us as an accessory app;
        // this call is defensive in case the plist is overridden.
        NSApp.setActivationPolicy(.accessory)

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

    /// Menu-driven panel toggle. Doesn't start/stop recording — the menu's job
    /// is to give the user a visual escape hatch; the hotkey is the dictation
    /// trigger.
    func requestPanelToggle() {
        guard ensureReady() else { return }
        appState.isPanelVisible.toggle()
    }

    // MARK: - Hotkey state machine

    private func handleHotkeyDown() {
        guard ensureReady() else { return }
        switch hotkey.mode {
        case .hold:
            startRecording()
        case .toggle:
            if recorder.state == .recording {
                stopRecording()
            } else {
                startRecording()
            }
        }
    }

    private func handleHotkeyUp() {
        guard hotkey.mode == .hold, recorder.state == .recording else { return }
        stopRecording()
    }

    private func startRecording() {
        appState.transcript = nil
        do {
            try recorder.start()
            appState.isPanelVisible = true
        } catch {
            Self.logger.error("Failed to start recording: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopRecording() {
        let samples = recorder.stop()
        guard !samples.isEmpty else { return }
        Task { [weak self] in
            await self?.transcribeAndShow(samples)
        }
    }

    private func transcribeAndShow(_ samples: [Float]) async {
        do {
            let text = try await transcriber.transcribe(samples: samples)
            appState.transcript = text.isEmpty ? nil : text
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
