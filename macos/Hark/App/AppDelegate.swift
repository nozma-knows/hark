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
    let aliasStore: AliasStore
    let polishProfileStore: PolishProfileStore
    let historyStore: HistoryStore
    let historyWindowController: HistoryWindowController
    let panelController: PanelWindowController
    let onboardingController: OnboardingWindowController
    let orchestrator: RecordingOrchestrator
    let updater: UpdateManager

    /// Opaque tokens for every NotificationCenter observer we install. We
    /// hold them so `deinit` can tear them down explicitly — without this,
    /// observers fire on a freed AppDelegate after app teardown (the runtime
    /// keeps the closures alive and they reach into nil `self` references).
    /// In practice AppDelegate lives until process exit, but keeping the
    /// pattern correct here documents the right way for future managers.
    ///
    /// `nonisolated(unsafe)` because `deinit` runs in a nonisolated context
    /// under Swift 6 strict concurrency — we can't access `@MainActor`
    /// storage from there. Safe in practice: append-only from MainActor
    /// during launch; read-only from deinit at teardown; no concurrent
    /// access possible.
    nonisolated(unsafe) private var notificationTokens: [NSObjectProtocol] = []

    override init() {
        let deps = Self.buildDependencies()
        appState = deps.state
        permissions = deps.perms
        hotkey = deps.hotkey
        recorder = deps.recorder
        transcriber = deps.transcriber
        claudeAuth = deps.claudeAuth
        sidecar = deps.sidecar
        aliasStore = deps.aliases
        polishProfileStore = deps.polishProfiles
        historyStore = deps.history
        // History window controller has a late-bound re-run closure; we
        // rewire it in `wireCallbacks()` once `orchestrator` exists.
        historyWindowController = HistoryWindowController(
            store: deps.history,
            onReRun: { _ in /* wired below */ }
        )
        onboardingController = deps.onboarding
        updater = UpdateManager()
        orchestrator = RecordingOrchestrator(
            appState: deps.state,
            hotkey: deps.hotkey,
            recorder: deps.recorder,
            transcriber: deps.transcriber,
            sidecar: deps.sidecar,
            permissions: deps.perms,
            needsOnboarding: { [onboarding = deps.onboarding] in onboarding.show() },
            polishProfileStore: deps.polishProfiles,
            historyStore: deps.history
        )
        panelController = PanelWindowController(
            appState: deps.state,
            recorder: deps.recorder,
            transcriber: deps.transcriber,
            actions: PanelActions(
                toggleRecording: { _ in /* wired below */ },
                cancelProcessing: { /* wired below */ },
                beginDrag: { /* wired below */ },
                updateDrag: { _ in /* wired below */ },
                endDrag: { _ in /* wired below */ }
            )
        )
        super.init()
        wireCallbacks()
    }

    /// Container for every stateful dependency the AppDelegate owns.
    /// Extracted from `init` so the initializer stays under SwiftLint's
    /// function_body_length threshold; pure construction with no
    /// observer wiring lives here.
    private struct Dependencies {
        let state: AppState
        let perms: PermissionsManager
        let hotkey: HotkeyManager
        let recorder: AudioRecorder
        let transcriber: Transcriber
        let claudeAuth: ClaudeAuth
        let aliases: AliasStore
        let polishProfiles: PolishProfileStore
        let history: HistoryStore
        let sidecar: AgentSidecar
        let onboarding: OnboardingWindowController
    }

    private static func buildDependencies() -> Dependencies {
        let claudeAuth = ClaudeAuth()
        let recorder = AudioRecorder()
        let transcriber = Transcriber()
        let perms = PermissionsManager()
        let sidecar = AgentSidecar(
            environmentProvider: { [claudeAuth] in
                var env = claudeAuth.sidecarEnvironment()
                // Pin the sidecar's alias dispatcher at the same file
                // the Swift store writes. Without this override, both
                // sides agree on the path by accident — explicit is safer.
                env["HARK_ALIASES_PATH"] = AliasStore.fileURL.path
                return env
            }
        )
        return Dependencies(
            state: AppState(),
            perms: perms,
            hotkey: HotkeyManager(),
            recorder: recorder,
            transcriber: transcriber,
            claudeAuth: claudeAuth,
            aliases: AliasStore(),
            polishProfiles: PolishProfileStore(),
            history: HistoryStore(),
            sidecar: sidecar,
            onboarding: OnboardingWindowController(
                permissions: perms,
                claudeAuth: claudeAuth,
                recorder: recorder,
                transcriber: transcriber
            )
        )
    }

    /// Plumbs the orchestrator, hotkey, panel, and permissions together.
    /// Extracted from `init` so the initializer stays under SwiftLint's
    /// function_body_length threshold; the work is purely "after super.init,
    /// hook up the live closures" — no construction state needed.
    private func wireCallbacks() {
        let captured = orchestrator
        hotkey.onKeyDown = { trigger in
            Task { @MainActor in captured.handleHotkeyDown(trigger) }
        }
        hotkey.onKeyUp = { trigger in
            Task { @MainActor in captured.handleHotkeyUp(trigger) }
        }
        let panel = panelController
        panelController.actions = PanelActions(
            toggleRecording: { trigger in
                Task { @MainActor in captured.togglePanelRecording(trigger) }
            },
            cancelProcessing: {
                Task { @MainActor in captured.cancelProcessing() }
            },
            beginDrag: { [weak panel] in
                panel?.beginDrag()
            },
            updateDrag: { [weak panel] translation in
                panel?.updateDrag(translation: translation)
            },
            endDrag: { [weak panel] translation in
                panel?.endDrag(translation: translation)
            }
        )
        // Auto-install / re-enable the global hotkey tap the instant the
        // user flips Accessibility or Input Monitoring in System Settings.
        // Removes the "now restart Hark" instruction from the permission
        // recovery flow.
        permissions.onPermissionGranted = { [weak self] in
            self?.hotkey.installIfNeeded()
        }

        // Restart the sidecar when the user saves or clears an API key in
        // Settings. The sidecar caches the AgentClient at spawn time based
        // on the env it was launched with — without the restart, a new key
        // wouldn't activate the Messages API path until the user quit and
        // relaunched Hark.
        claudeAuth.onCredentialsChanged = { [weak self] in
            self?.sidecar.stop()
        }

        // History "Re-run" button: hands the saved entry back to the
        // orchestrator, which dispatches it through the same pipeline
        // branch that originally produced it.
        historyWindowController.onReRun = { [weak orchestrator = orchestrator] entry in
            orchestrator?.reRun(entry)
        }
    }

    func applicationDidFinishLaunching(_: Notification) {
        // Install crash capture FIRST. Any subsequent fatal signal /
        // uncaught exception during the rest of startup will produce a
        // .log under ~/Library/Logs/Hark/crashes/ that we can ask the
        // user to attach to a bug report.
        CrashReporter.install()

        // Opt-in HTTP upload sink. nil when the user hasn't configured
        // an endpoint in Settings → General → Crash uploads — leaves
        // the sink unset so crashes stay local-only by default. Wired
        // immediately after install() so any crash during the rest of
        // applicationDidFinishLaunching also gets uploaded if the user
        // has opted in.
        CrashReporter.sink = CrashUploadPreferences.buildSinkIfConfigured()

        // First line of the file log: marks launch boundary so support
        // bundles always have a clear "this is where this session started"
        // anchor when the user reports a bug from a long-running install.
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "unknown"
        FileLogger.shared.log(.info, category: "AppDelegate", "Hark \(version) launched (pid=\(getpid()))")

        // Hark is a regular dock app (Wispr Flow-style). LSUIElement is
        // false in Info.plist so the icon shows up in the Dock.
        NSApp.setActivationPolicy(.regular)

        // Pill UI is visible from launch — Wispr Flow-style always-on
        // bottom-center indicator.
        panelController.showAlways()

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: NSApplication.didBecomeActiveNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                // Permissions and Claude auth can flip silently while the
                // user is in System Settings / Terminal; re-poll on
                // foreground return. Also retry installing the global-hotkey
                // event tap if it failed at launch because Accessibility
                // hadn't been granted yet — saves the user from needing to
                // manually relaunch Hark.
                MainActor.assumeIsolated {
                    self?.permissions.refresh()
                    self?.claudeAuth.refresh()
                    self?.hotkey.installIfNeeded()
                }
            }
        )

        notificationTokens.append(
            NotificationCenter.default.addObserver(
                forName: .openHarkSettings,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated { self?.openSettingsWindow() }
            }
        )

        onboardingController.showIfNeeded()

        // Warm the previously selected model in the background so the first
        // dictation doesn't pay the load cost. If the model isn't downloaded
        // yet, this kicks off the download in parallel.
        transcriber.bootstrap()
    }

    deinit {
        // Tear down every observer token we installed in
        // `applicationDidFinishLaunching`. Without this, the closures
        // outlive AppDelegate and fire on its zeroed-out memory if the
        // system posts a late notification. AppDelegate normally lives
        // until process exit so this is defensive, but the discipline
        // matters for future managers that DO get torn down mid-run.
        for token in notificationTokens {
            NotificationCenter.default.removeObserver(token)
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

        let candidates = NSApp.windows.map { window in
            Self.WindowDescriptor(
                identifier: window.identifier?.rawValue,
                title: window.title,
                isVisible: window.isVisible
            )
        }
        if let index = Self.indexOfSettingsWindow(in: candidates) {
            let window = NSApp.windows[index]
            Self.logger.info("Re-focusing existing Settings window: \(window.title, privacy: .public)")
            window.makeKeyAndOrderFront(nil)
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

    /// Pure-function variant of "find the Settings window" — takes a
    /// descriptor of every open window and returns the index of the
    /// first one that matches our settings-recognition rules. Extracted
    /// so the recognition logic can be tested without touching `NSApp`.
    struct WindowDescriptor: Equatable {
        let identifier: String?
        let title: String
        let isVisible: Bool
    }

    /// Recognize a SwiftUI Settings (or older "Preferences") window from
    /// its identifier + title. SwiftUI's Settings scene gives the window
    /// either identifier "Settings" or title "Settings"; older macOS
    /// terminology uses "Preferences."
    nonisolated static func indexOfSettingsWindow(in windows: [WindowDescriptor]) -> Int? {
        windows.firstIndex(where: { window in
            let id = window.identifier?.lowercased() ?? ""
            let title = window.title.lowercased()
            return id.contains("settings") || title == "settings"
                || id.contains("preferences") || title == "preferences"
        })
    }
}
