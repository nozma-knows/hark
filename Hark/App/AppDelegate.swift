import AppKit
import OSLog

extension Notification.Name {
    /// Posted by the pill's settings button. AppDelegate listens and forwards
    /// to `NSApp.sendAction(showSettingsWindow:)` — which works reliably from
    /// the AppDelegate context but is unreliable when called directly from a
    /// SwiftUI button inside a non-activating NSPanel.
    static let openHarkSettings = Notification.Name("co.milbo.hark.openSettings")
}

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "AppDelegate")

    let appState: AppState
    let permissions: PermissionsManager
    let hotkey: HotkeyManager
    let recorder: AudioRecorder
    let transcriber: Transcriber
    let claudeAuth: ClaudeAuth
    let sidecar: AgentSidecar
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController

    override init() {
        let state = AppState()
        let perms = PermissionsManager()
        let hotkeyManager = HotkeyManager()
        let audioRecorder = AudioRecorder()
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
        recorder = audioRecorder
        transcriber = transcriberInstance
        claudeAuth = claudeAuthInstance
        sidecar = sidecarInstance
        panelController = PanelWindowController(
            appState: state,
            recorder: audioRecorder,
            transcriber: transcriberInstance
        )
        onboardingController = OnboardingWindowController(
            permissions: perms,
            claudeAuth: claudeAuthInstance
        )
        super.init()

        hotkey.onKeyDown = { [weak self] trigger in self?.handleHotkeyDown(trigger) }
        hotkey.onKeyUp = { [weak self] trigger in self?.handleHotkeyUp(trigger) }
    }

    @ObservationIgnored private var activeTrigger: HotkeyTrigger = .dictate

    func applicationDidFinishLaunching(_: Notification) {
        // Hark is a regular dock app (Wispr Flow-style). LSUIElement is
        // false in Info.plist so the icon shows up in the Dock.
        NSApp.setActivationPolicy(.regular)

        // Pill UI is visible from launch — Wispr Flow-style always-on
        // bottom-center indicator.
        panelController.showAlways()

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

        NotificationCenter.default.addObserver(
            forName: .openHarkSettings,
            object: nil,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                NSApp.activate(ignoringOtherApps: true)
                let selector = NSSelectorFromString("showSettingsWindow:")
                NSApp.sendAction(selector, to: nil, from: nil)
            }
        }

        onboardingController.showIfNeeded()

        // Warm the previously selected model in the background so the first
        // dictation doesn't pay the load cost. If the model isn't downloaded
        // yet, this kicks off the download in parallel.
        transcriber.bootstrap()
    }

    // MARK: - Hotkey state machine

    private func handleHotkeyDown(_ trigger: HotkeyTrigger) {
        guard ensureReady() else { return }
        switch hotkey.mode {
        case .hold:
            startRecording(trigger: trigger)
        case .toggle:
            if recorder.state == .recording {
                stopRecording()
            } else {
                startRecording(trigger: trigger)
            }
        }
    }

    private func handleHotkeyUp(_: HotkeyTrigger) {
        guard hotkey.mode == .hold, recorder.state == .recording else { return }
        stopRecording()
    }

    private func startRecording(trigger: HotkeyTrigger) {
        activeTrigger = trigger
        appState.transcript = nil
        appState.transcriptInsertFailed = false
        do {
            try recorder.start()
        } catch {
            Self.logger.error("Failed to start recording: \(String(describing: error), privacy: .public)")
        }
    }

    private func stopRecording() {
        let samples = recorder.stop()
        guard !samples.isEmpty else { return }
        // Use the LIVE trigger at the moment Fn is released — not the locked-in
        // value from Fn-down. This lets the user add/remove Ctrl mid-press and
        // the resulting action matches what they were holding when they let go.
        let trigger = hotkey.currentTrigger
        Self.logger.info("stopRecording with trigger: \(String(describing: trigger), privacy: .public)")
        Task { [weak self] in
            await self?.finalizeTranscript(samples, trigger: trigger)
        }
    }

    private func finalizeTranscript(_ samples: [Float], trigger: HotkeyTrigger) async {
        do {
            let raw = try await transcriber.transcribe(samples: samples)
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return }

            // Polish via Claude before delivering. Falls back to raw on any
            // failure (no auth, sidecar crash, network) so dictation always
            // produces something.
            appState.isPolishing = true
            let text = await polishOrFallback(trimmed)
            appState.isPolishing = false

            switch trigger {
            case .dictate:
                appState.transcript = text
            case .insert:
                let hasInput = InputInserter.hasFocusedTextInput()
                Self.logger.info("Insert mode: hasFocusedInput=\(hasInput, privacy: .public)")
                if hasInput {
                    InputInserter.paste(text)
                    // Don't surface a panel — the text landed where the
                    // user was already typing.
                } else {
                    appState.transcript = text
                    appState.transcriptInsertFailed = true
                }
            }
        } catch {
            appState.isPolishing = false
            Self.logger.error("Transcribe failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Send the trimmed Whisper output to Claude (via the Bun sidecar) for
    /// punctuation / casing / filler cleanup. Returns the polished string,
    /// or the raw input unchanged on any failure. Side-effect: accumulates
    /// usage stats into `appState.claudeUsage` (persisted).
    private func polishOrFallback(_ raw: String) async -> String {
        struct Params: Encodable { let text: String }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadTokens: Int?
            let cacheCreationTokens: Int?
        }
        struct Result: Decodable {
            let polished: String
            let changed: Bool
            let usage: Usage?
        }
        do {
            let result: Result = try await sidecar.request(
                method: "polishTranscript",
                params: Params(text: raw),
                result: Result.self
            )
            if let usage = result.usage {
                var stats = appState.claudeUsage
                stats.add(
                    input: usage.inputTokens ?? 0,
                    output: usage.outputTokens ?? 0,
                    cacheRead: usage.cacheReadTokens ?? 0,
                    cacheCreation: usage.cacheCreationTokens ?? 0
                )
                stats.save()
                appState.claudeUsage = stats
            }
            return result.polished
        } catch {
            Self.logger.error("Polish failed (using raw): \(String(describing: error), privacy: .public)")
            return raw
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
