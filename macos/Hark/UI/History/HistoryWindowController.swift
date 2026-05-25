import AppKit
import SwiftUI

/// Owns the History window. Standalone (titled) window like the
/// onboarding flow — re-uses an existing instance so multiple
/// `show()` calls just re-focus instead of opening duplicates.
@MainActor
final class HistoryWindowController: NSObject {
    private static let initialSize = NSSize(width: 760, height: 520)
    private static let minSize = NSSize(width: 560, height: 360)

    private let store: HistoryStore
    /// Re-issues a transcript through the recording pipeline. `var`
    /// because AppDelegate constructs the controller before the
    /// orchestrator exists (two-stage init) and rewires the real
    /// closure in `wireCallbacks()` — the bound value is captured
    /// per-show, not per-construction, so the late-binding works.
    var onReRun: (HistoryEntry) -> Void
    private var window: NSWindow?

    init(store: HistoryStore, onReRun: @escaping (HistoryEntry) -> Void) {
        self.store = store
        self.onReRun = onReRun
        super.init()
    }

    /// Show the window, creating it lazily. Activates the app so the
    /// window is focused even when invoked from the menu bar.
    func show() {
        let window = window ?? makeWindow()
        self.window = window
        window.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    private func makeWindow() -> NSWindow {
        let window = NSWindow(
            contentRect: NSRect(origin: .zero, size: Self.initialSize),
            styleMask: [.titled, .closable, .resizable, .miniaturizable],
            backing: .buffered,
            defer: false
        )
        window.title = "Hark History"
        window.minSize = Self.minSize
        window.isReleasedWhenClosed = false
        window.center()
        // Closure-injected re-run keeps HistoryView decoupled from
        // RecordingOrchestrator — the window controller is the only
        // place that knows the orchestrator exists.
        window.contentView = NSHostingView(rootView: HistoryView(store: store, onReRun: onReRun))
        return window
    }
}
