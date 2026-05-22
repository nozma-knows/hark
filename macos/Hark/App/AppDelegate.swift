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
        // Construct AppDelegate first, then wire the panel actions in
        // applicationDidFinishLaunching (closures need `self`, which we can't
        // capture before super.init()).
        panelController = PanelWindowController(
            appState: state,
            recorder: audioRecorder,
            transcriber: transcriberInstance,
            actions: PanelActions(toggleRecording: { _ in /* wired below */ })
        )
        onboardingController = OnboardingWindowController(
            permissions: perms,
            claudeAuth: claudeAuthInstance
        )
        super.init()

        hotkey.onKeyDown = { [weak self] trigger in self?.handleHotkeyDown(trigger) }
        hotkey.onKeyUp = { [weak self] trigger in self?.handleHotkeyUp(trigger) }
        panelController.actions = PanelActions(
            toggleRecording: { [weak self] trigger in self?.togglePanelRecording(trigger) }
        )
    }

    @ObservationIgnored private var activeTrigger: HotkeyTrigger = .dictate
    /// Set when the pill UI (record button or menu item) initiates a recording;
    /// nil for hotkey-driven recordings. Read on stop to decide which trigger
    /// the finalize step should use.
    @ObservationIgnored private var manualRecordingTrigger: HotkeyTrigger?

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
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.openSettingsWindow() }
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
        // Don't stop a recording the pill explicitly started — the user must
        // click the record button to end it.
        guard manualRecordingTrigger == nil else { return }
        stopRecording()
    }

    /// Pill UI entry point: click-to-toggle recording. The selected mode
    /// (.dictate / .insert / .command) is preserved through the finalize
    /// step, regardless of which Fn modifiers happen to be down.
    func togglePanelRecording(_ trigger: HotkeyTrigger) {
        guard ensureReady() else { return }
        if recorder.state == .recording {
            stopRecording()
        } else {
            manualRecordingTrigger = trigger
            startRecording(trigger: trigger)
        }
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
        // For pill-initiated recordings, use the trigger that was selected at
        // start (the user explicitly chose Execute / Fill input / dictate via
        // the UI). For hotkey-driven recordings, use the LIVE trigger at
        // release time — lets the user add/remove Ctrl mid-press and the
        // resulting action matches what they were holding when they let go.
        let trigger = manualRecordingTrigger ?? hotkey.currentTrigger
        manualRecordingTrigger = nil
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

            switch trigger {
            case .command:
                // Voice command: skip the polish step (Claude is going to
                // interpret intent anyway) and send straight to executeCommand.
                await executeVoiceCommand(trimmed)

            case .dictate, .insert:
                // Polish via Claude before delivering. Falls back to raw on
                // any failure so dictation always produces something.
                appState.isPolishing = true
                let text = await polishOrFallback(trimmed)
                appState.isPolishing = false

                if trigger == .insert {
                    let hasInput = InputInserter.hasFocusedTextInput()
                    Self.logger.info("Insert mode: hasFocusedInput=\(hasInput, privacy: .public)")
                    if hasInput {
                        InputInserter.paste(text)
                    } else {
                        appState.transcript = text
                        appState.transcriptInsertFailed = true
                    }
                } else {
                    appState.transcript = text
                }
            }
        } catch {
            appState.isPolishing = false
            appState.isExecutingCommand = false
            Self.logger.error("Transcribe failed: \(String(describing: error), privacy: .public)")
        }
    }

    /// Send the transcript to the Agent SDK in the sidecar; it drives Bash
    /// to perform a macOS action (open app, run AppleScript, run Shortcut).
    /// Shows live state in the pill (isExecutingCommand → commandResult).
    private func executeVoiceCommand(_ transcript: String) async {
        struct Params: Encodable { let transcript: String }
        struct Usage: Decodable {
            let inputTokens: Int?
            let outputTokens: Int?
            let cacheReadTokens: Int?
            let cacheCreationTokens: Int?
        }
        struct Result: Decodable {
            let summary: String
            let succeeded: Bool
            let usage: Usage?
        }

        appState.isExecutingCommand = true
        defer { appState.isExecutingCommand = false }

        do {
            let result: Result = try await sidecar.request(
                method: "executeCommand",
                params: Params(transcript: transcript),
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
            appState.commandResult = .init(summary: result.summary, succeeded: result.succeeded)
            // Auto-clear the result after a few seconds so the pill returns
            // to its idle state without the user dismissing.
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(5))
                guard let self else { return }
                if appState.commandResult?.summary == result.summary {
                    appState.commandResult = nil
                }
            }
        } catch {
            let detail = String(describing: error)
            Self.logger.error("executeCommand failed: \(detail, privacy: .public)")
            appState.commandResult = .init(
                summary: "Command failed: \(error.localizedDescription)",
                succeeded: false
            )
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

    /// Open the SwiftUI Settings window. Tries multiple paths because
    /// `NSApp.sendAction(showSettingsWindow:)` doesn't always reach SwiftUI's
    /// Settings scene from a fresh process: first focus an existing Settings
    /// window if one's around; otherwise post the selector after activating
    /// the app with a small delay so SwiftUI's responder chain is settled.
    private func openSettingsWindow() {
        Self.logger.info("openSettingsWindow invoked")
        NSApp.activate(ignoringOtherApps: true)

        // Path A: re-focus an already-open Settings window.
        let existing = NSApp.windows.first(where: { window in
            let id = window.identifier?.rawValue.lowercased() ?? ""
            let title = window.title.lowercased()
            let isSettings = id.contains("settings") || title == "settings"
                || id.contains("preferences") || title == "preferences"
            return isSettings && window.isVisible == false || isSettings
        })
        if let existing {
            Self.logger.info("Re-focusing existing Settings window: \(existing.title, privacy: .public)")
            existing.makeKeyAndOrderFront(nil)
            return
        }

        // Path B: ask SwiftUI to open the Settings scene. Dispatch after the
        // current run-loop tick so .activate has time to settle.
        DispatchQueue.main.async {
            let selector = NSSelectorFromString("showSettingsWindow:")
            let responds = NSApp.responds(to: selector)
            Self.logger.info("NSApp responds(showSettingsWindow:): \(responds)")
            NSApp.sendAction(selector, to: nil, from: nil)
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
