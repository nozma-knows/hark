import AppKit
import SwiftUI

@main
struct HarkApp: App {
    var body: some Scene {
        MenuBarExtra {
            HarkMenu()
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
    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
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
