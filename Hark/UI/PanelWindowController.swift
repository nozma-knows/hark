import AppKit
import SwiftUI

/// Owns the floating, borderless, non-activating `NSPanel` that hosts Hark's
/// transient UI. The panel lives outside SwiftUI's scene graph so it can:
/// (a) appear without taking focus from the user's current app,
/// (b) float above all standard windows on every Space,
/// (c) be summoned/dismissed imperatively from anywhere in the app.
@MainActor
final class PanelWindowController {
    private static let defaultSize = NSSize(width: 560, height: 320)
    private static let cornerRadius: CGFloat = 14

    private var panel: NSPanel?

    var isVisible: Bool {
        panel?.isVisible ?? false
    }

    func show() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionOnActiveScreen(panel)
        panel.makeKeyAndOrderFront(nil)
    }

    func hide() {
        panel?.orderOut(nil)
    }

    func toggle() {
        if isVisible { hide() } else { show() }
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

        let host = NSHostingView(rootView: PanelRootView())
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
