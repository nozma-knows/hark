import AppKit
import SwiftUI

@main
struct HarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate

    var body: some Scene {
        MenuBarExtra {
            HarkMenu(appState: delegate.appState) {
                delegate.requestPanelToggle()
            }
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Hark")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(hotkey: delegate.hotkey, transcriber: delegate.transcriber)
        }
    }
}

private struct HarkMenu: View {
    @Bindable var appState: AppState
    let onTogglePanel: () -> Void

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        Button(appState.isPanelVisible ? "Hide Hark" : "Show Hark") {
            onTogglePanel()
        }
        .keyboardShortcut(.space, modifiers: [.control, .option])

        Divider()

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("About Hark") {
            NSApp.orderFrontStandardAboutPanel(nil)
            NSApp.activate(ignoringOtherApps: true)
        }

        Divider()

        Button("Quit Hark") {
            NSApplication.shared.terminate(nil)
        }
        .keyboardShortcut("q", modifiers: [.command])
    }
}
