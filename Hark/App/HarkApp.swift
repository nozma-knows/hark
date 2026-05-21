import AppKit
import SwiftUI

@main
struct HarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate

    var body: some Scene {
        MenuBarExtra {
            HarkMenu(appState: delegate.appState)
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Hark")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView()
        }
    }
}

private struct HarkMenu: View {
    @Bindable var appState: AppState

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        Button(appState.isPanelVisible ? "Hide Hark" : "Show Hark") {
            appState.isPanelVisible.toggle()
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
