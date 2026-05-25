import AppKit
import SwiftUI

/// Owns the standalone onboarding NSWindow. Unlike the floating panel, this
/// window is a regular titled window that activates Hark when shown — first
/// run is one of the few moments we *do* want focus.
///
/// While the window is visible we poll `AXIsProcessTrusted` on a half-second
/// timer. `NSApplication.didBecomeActiveNotification` is not reliable for
/// accessory (`LSUIElement: true`) apps when the onboarding window stays
/// in front of System Settings — and TCC's notifications aren't public.
/// Polling is the robust fallback.
@MainActor
final class OnboardingWindowController: NSObject {
    private static let windowSize = NSSize(width: 520, height: 520)
    private static let pollInterval: TimeInterval = 0.5

    private let permissions: PermissionsManager
    private let claudeAuth: ClaudeAuth
    private let recorder: AudioRecorder
    private let transcriber: Transcriber
    private var window: NSWindow?
    private var pollTimer: Timer?

    init(
        permissions: PermissionsManager,
        claudeAuth: ClaudeAuth,
        recorder: AudioRecorder,
        transcriber: Transcriber
    ) {
        self.permissions = permissions
        self.claudeAuth = claudeAuth
        self.recorder = recorder
        self.transcriber = transcriber
        super.init()
    }

    var isVisible: Bool {
        window?.isVisible ?? false
    }

    /// Show the onboarding window if any required permission is still missing.
    /// Idempotent: returns `true` if a window is now visible, `false` if perms
    /// were already complete and nothing was shown.
    @discardableResult
    func showIfNeeded() -> Bool {
        permissions.refresh()
        if permissions.allGranted {
            return false
        }
        show()
        return true
    }

    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.center()
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        startPolling()
    }

    func close() {
        stopPolling()
        window?.close()
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.windowSize),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Welcome to Hark"
        window.isReleasedWhenClosed = false
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.delegate = self

        let content = OnboardingView(
            permissions: permissions,
            claudeAuth: claudeAuth,
            recorder: recorder,
            transcriber: transcriber
        ) { [weak self] in
            self?.close()
        }
        window.contentView = NSHostingView(rootView: content)
        return window
    }

    private func startPolling() {
        stopPolling()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.permissions.refresh()
                self?.claudeAuth.refresh()
            }
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    private func stopPolling() {
        pollTimer?.invalidate()
        pollTimer = nil
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        // Closing the window with permissions still missing is allowed — the
        // user can re-open it from the menu later (we'll add that surface in
        // a future PR). For now we just let it close.
        stopPolling()
    }
}
