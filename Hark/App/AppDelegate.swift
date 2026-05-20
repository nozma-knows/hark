import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let permissions: PermissionsManager
    let hotkey: HotkeyManager
    let recorder: AudioRecorder
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        let hotkeyManager = HotkeyManager()
        let audioRecorder = AudioRecorder()
        appState = state
        permissions = perms
        hotkey = hotkeyManager
        recorder = audioRecorder
        panelController = PanelWindowController(appState: state, recorder: audioRecorder)
        onboardingController = OnboardingWindowController(permissions: perms)
        super.init()

        // The hotkey is the second entrypoint to the panel (the menu is the
        // first). Route both through the same gated method so the permission
        // check happens in exactly one place.
        hotkey.onKeyDown = { [weak self] in
            self?.requestPanelToggle()
        }
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
    }

    /// User-initiated request to toggle the floating panel. If any required
    /// permission is missing, route to onboarding instead — the panel itself
    /// is useless until the mic + global hotkey are wired through, and forcing
    /// the gate here keeps later flows (record / hotkey) honest by default.
    func requestPanelToggle() {
        permissions.refresh()
        guard permissions.allGranted else {
            onboardingController.show()
            return
        }
        appState.isPanelVisible.toggle()
    }
}
