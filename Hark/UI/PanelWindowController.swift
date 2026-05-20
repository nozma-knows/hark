import AppKit
import Observation
import SwiftUI

/// Owns the floating, borderless, non-activating `NSPanel` that hosts Hark's
/// transient UI. The panel lives outside SwiftUI's scene graph so it can:
/// (a) appear without taking focus from the user's current app,
/// (b) float above all standard windows on every Space,
/// (c) be summoned/dismissed declaratively by toggling `AppState.isPanelVisible`.
@MainActor
final class PanelWindowController: NSObject {
    private static let defaultSize = NSSize(width: 560, height: 320)
    private static let cornerRadius: CGFloat = 14

    private let appState: AppState
    private let recorder: AudioRecorder
    private var panel: NSPanel?

    init(appState: AppState, recorder: AudioRecorder) {
        self.appState = appState
        self.recorder = recorder
        super.init()
        observeVisibility()
    }

    private func observeVisibility() {
        // `withObservationTracking` fires once per change; re-register inside
        // `onChange` to keep listening for subsequent toggles.
        withObservationTracking {
            _ = appState.isPanelVisible
        } onChange: { [weak self] in
            Task { @MainActor [weak self] in
                guard let self else { return }
                syncPanelVisibility()
                observeVisibility()
            }
        }
    }

    private func syncPanelVisibility() {
        if appState.isPanelVisible {
            present()
        } else {
            dismiss()
        }
    }

    private func present() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    private func dismiss() {
        panel?.orderOut(nil)
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: Self.defaultSize),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = true
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.isMovableByWindowBackground = true
        panel.hidesOnDeactivate = false
        panel.animationBehavior = .utilityWindow
        panel.delegate = self

        let host = NSHostingView(rootView: PanelRootView(recorder: recorder))
        host.wantsLayer = true
        host.layer?.cornerRadius = Self.cornerRadius
        host.layer?.masksToBounds = true
        panel.contentView = host
        return panel
    }

    private func positionOnActiveScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Centered horizontally; positioned ~25% from the top edge of the visible area.
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.maxY - size.height - visible.height * 0.25
        )
        panel.setFrameOrigin(origin)
    }
}

extension PanelWindowController: NSWindowDelegate {
    /// Mirror external closes (e.g., system-initiated) back into `AppState`
    /// so the menu label and any future bindings stay correct.
    func windowWillClose(_: Notification) {
        if appState.isPanelVisible {
            appState.isPanelVisible = false
        }
    }
}
