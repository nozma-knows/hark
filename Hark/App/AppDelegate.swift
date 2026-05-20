import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let permissions: PermissionsManager
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        appState = state
        permissions = perms
        panelController = PanelWindowController(appState: state)
        onboardingController = OnboardingWindowController(permissions: perms)
        super.init()
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
}
