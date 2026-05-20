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
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        let hotkeyManager = HotkeyManager()
        let audioRecorder = AudioRecorder()
        let transcriberInstance = Transcriber()
        appState = state
        permissions = perms
        hotkey = hotkeyManager
        recorder = audioRecorder
        transcriber = transcriberInstance
        panelController = PanelWindowController(appState: state, recorder: audioRecorder)
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
            // Permissions can flip silently while the user is in System Settings;
            // re-poll whenever Hark returns to the foreground.
            MainActor.assumeIsolated { self?.permissions.refresh() }
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
        do {
            try recorder.start()
            appState.isPanelVisible = true
        } catch {
            Self.logger.error("Failed to start recording: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopRecording() {
        _ = recorder.stop()
        // PR 6 wires these samples into WhisperKit. For PR 5 the samples
        // are intentionally discarded — the goal is to validate that the
        // capture → UI loop feels right.
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
