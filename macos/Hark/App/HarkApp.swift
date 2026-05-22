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
            // Template image — system tints to match the menu bar appearance
            // (black on light menu bars, white on dark). All three modifiers
            // are required:
            //   `.resizable()` + `.frame(18×18)`: source asset is 1024×1024;
            //       MenuBarExtra refuses to render unconstrained images.
            //   `.renderingMode(.template)`: the asset catalog's
            //       template-rendering-intent isn't always honored by
            //       SwiftUI on macOS — without an explicit override the
            //       image loads as full-color black on transparent, which
            //       is invisible against the macOS menu bar's dark blur.
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .frame(width: 18, height: 18)
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
