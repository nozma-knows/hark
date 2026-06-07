import AppKit
import SwiftUI

@main
struct HarkApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self)
    private var delegate

    /// Hand-sized 18×18 template image for the MenuBarExtra label.
    ///
    /// MenuBarExtra ignores SwiftUI's .resizable()/.frame() modifiers on its
    /// label image and uses the source asset's natural size — for our 1024×1024
    /// BrandMark, that produces a 1040-point-wide status item that sits
    /// off-screen at X=-57 and looks like the icon is "missing." Setting
    /// `.size` directly on a copy of the NSImage (and marking it as template
    /// here so it tints with the menu bar appearance) is the only way to
    /// constrain the rendered dimensions.
    private static let menuBarIcon: NSImage = {
        let img = (NSImage(named: "BrandMark")?.copy() as? NSImage) ?? NSImage()
        img.size = NSSize(width: 18, height: 18)
        img.isTemplate = true
        return img
    }()

    var body: some Scene {
        MenuBarExtra {
            HarkMenu(
                hotkey: delegate.hotkey,
                recorder: delegate.recorder,
                transcriber: delegate.transcriber,
                updater: delegate.updater,
                permissions: delegate.permissions,
                claudeAuth: delegate.claudeAuth,
                onShowWelcome: { delegate.onboardingController.show() },
                onShowHistory: { delegate.historyWindowController.show() }
            )
        } label: {
            Image(nsImage: Self.menuBarIcon)
                .accessibilityLabel("Hark")
        }
        .menuBarExtraStyle(.menu)

        Settings {
            SettingsView(
                hotkey: delegate.hotkey,
                transcriber: delegate.transcriber,
                claudeAuth: delegate.claudeAuth,
                appState: delegate.appState,
                aliasStore: delegate.aliasStore,
                polishProfileStore: delegate.polishProfileStore,
                pillPosition: PillPositionSettings(
                    model: delegate.panelController.positionModel,
                    hasAnyStoredAnchor: { [panel = delegate.panelController] in
                        panel.hasAnyStoredAnchor
                    },
                    resetActive: { [panel = delegate.panelController] in
                        panel.resetPositionOnActiveScreen()
                    },
                    resetAll: { [panel = delegate.panelController] in
                        panel.resetPositionOnAllScreens()
                    }
                ),
                onResetConversation: { [sidecar = delegate.sidecar] in
                    // Fire-and-forget: the sidecar's resetConversation
                    // handler is a single store.clear() call that never
                    // fails meaningfully. If the sidecar is down, the
                    // ring buffer is already empty (process restart
                    // clears it), so a swallowed error here is correct
                    // behavior.
                    Task { @MainActor in
                        struct ResetResult: Decodable { let cleared: Bool }
                        _ = try? await sidecar.request(
                            method: "resetConversation",
                            result: ResetResult.self
                        )
                    }
                }
            )
        }
    }
}

private struct HarkMenu: View {
    @Bindable var hotkey: HotkeyManager
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    @Bindable var updater: UpdateManager
    @Bindable var permissions: PermissionsManager
    @Bindable var claudeAuth: ClaudeAuth
    let onShowWelcome: () -> Void
    let onShowHistory: () -> Void

    @Environment(\.openSettings)
    private var openSettings

    var body: some View {
        Text(statusLine)
            .font(.caption)

        Divider()

        // Discoverable re-entry into onboarding. While a required
        // permission is still missing the wizard is mid-flow — label it
        // "Finish setup…" so a user who closed the window has an obvious
        // way back instead of a silent dead end.
        Button(permissions.allGranted ? "Welcome…" : "Finish setup…") {
            onShowWelcome()
        }

        // Post-skip nudge: once setup is otherwise done but Claude was
        // skipped, Hark only produces raw transcripts. Surface a way
        // back to connect it — only after onboarding finished, so this
        // doesn't pile on top of the live in-wizard Claude step.
        if
            OnboardingProgress.hasCompleted,
            permissions.allGranted,
            !claudeAuth.method.isResolved
        {
            Button("Connect Claude…") {
                onShowWelcome()
            }
        }

        Button("History…") {
            onShowHistory()
        }
        .keyboardShortcut("y", modifiers: [.command])

        Button("Settings…") {
            openSettings()
        }
        .keyboardShortcut(",", modifiers: [.command])

        Button("Check for Updates…") {
            updater.checkForUpdates()
        }
        .disabled(!updater.canCheckForUpdates)

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
