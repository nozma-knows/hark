import AppKit
import SwiftUI

/// Owns the standalone onboarding NSWindow. Unlike the floating panel, this
/// window is a regular titled window that activates Hark when shown — first
/// run is one of the few moments we *do* want focus.
@MainActor
final class OnboardingWindowController: NSObject {
    private static let windowSize = NSSize(width: 480, height: 520)

    private let permissions: PermissionsManager
    private var window: NSWindow?

    init(permissions: PermissionsManager) {
        self.permissions = permissions
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
    }

    func close() {
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

        let content = OnboardingView(permissions: permissions) { [weak self] in
            self?.close()
        }
        window.contentView = NSHostingView(rootView: content)
        return window
    }
}

extension OnboardingWindowController: NSWindowDelegate {
    func windowWillClose(_: Notification) {
        // Closing the window with permissions still missing is allowed — the
        // user can re-open it from the menu later (we'll add that surface in
        // a future PR). For now we just let it close.
    }
}
