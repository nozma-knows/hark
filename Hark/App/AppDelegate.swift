import AppKit

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    let appState: AppState
    let panelController: PanelWindowController

    override init() {
        let state = AppState()
        appState = state
        panelController = PanelWindowController(appState: state)
        super.init()
    }

    func applicationDidFinishLaunching(_: Notification) {
        // LSUIElement in Info.plist already runs us as an accessory app;
        // this call is defensive in case the plist is overridden.
        NSApp.setActivationPolicy(.accessory)
    }
}
