import AppKit
import SwiftUI

@main
struct HarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate

    var body: some Scene {
        MenuBarExtra {
            HarkMenu(
                hotkey: delegate.hotkey,
                recorder: delegate.recorder,
                transcriber: delegate.transcriber,
                onShowWelcome: { delegate.onboardingController.show() }
            )
        } label: {
            Image(systemName: "waveform")
                .accessibilityLabel("Hark")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                hotkey: delegate.hotkey,
                transcriber: delegate.transcriber,
                claudeAuth: delegate.claudeAuth,
                appState: delegate.appState
            )
        }
    }
}

private struct HarkMenu: View {
    @Bindable var hotkey: HotkeyManager
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    let onShowWelcome: () -> Void

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        Text(statusLine)
            .font(.caption)

        Divider()

        Button("Welcome…") {
            onShowWelcome()
        }

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

    private var statusLine: String {
        let state = if recorder.state == .recording {
            "Recording"
        } else if case .transcribing = transcriber.state {
            "Transcribing"
        } else {
            "Hark"
        }
        return "\(state) · \(hotkey.label) · \(hotkey.mode.label)"
    }
}
