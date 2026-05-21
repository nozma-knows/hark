import AppKit
import OSLog

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "AppDelegate")

    let appState: AppState
    let permissions: PermissionsManager
    let hotkey: HotkeyManager
    let transcriber: Transcriber
    let claudeAuth: ClaudeAuth
    let sidecar: AgentSidecar
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        let hotkeyManager = HotkeyManager()
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
        transcriber = transcriberInstance
        claudeAuth = claudeAuthInstance
        sidecar = sidecarInstance
        panelController = PanelWindowController(
            appState: state,
            transcriber: transcriberInstance
        )
        onboardingController = OnboardingWindowController(
            permissions: perms,
            claudeAuth: claudeAuthInstance
        )
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
            startStream()
        case .toggle:
            if isStreaming {
                stopStream()
            } else {
                startStream()
            }
        }
    }

    private func handleHotkeyUp() {
        guard hotkey.mode == .hold, isStreaming else { return }
        stopStream()
    }

    private var isStreaming: Bool {
        if case .recording = transcriber.state { return true }
        return false
    }

    private func startStream() {
        appState.transcript = nil
        appState.isPanelVisible = true
        Task { [weak self] in
            guard let self else { return }
            do {
                try await transcriber.startStream()
            } catch {
                Self.logger.error("Failed to start stream: \(String(describing: error), privacy: .public)")
            }
        }
    }

    private func stopStream() {
        Task { [weak self] in
            guard let self else { return }
            let text = await transcriber.stopStream()
            appState.transcript = text.isEmpty ? nil : text
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
