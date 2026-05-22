import AppKit
import Observation
import SwiftUI

/// Owns the always-visible Wispr Flow-style pill panel at the bottom-center
/// of the active screen. The panel:
/// - is borderless + non-activating (clicks pass through outside the pill)
/// - floats above all standard windows on every Space
/// - doesn't take focus from the user's current app
/// - resizes its frame as the SwiftUI content grows / shrinks between
///   idle / recording / processing / transcript states
@MainActor
final class PanelWindowController: NSObject {
    private static let panelHeight: CGFloat = 72
    private static let panelWidth: CGFloat = 680
    /// Vertical distance between the panel and the top of the Dock. Anything
    /// smaller and the pill visually rides the Dock edge (and users hover
    /// through Dock items trying to reach it).
    private static let bottomInset: CGFloat = 22

    private let appState: AppState
    private let recorder: AudioRecorder
    private let transcriber: Transcriber
    /// Mutable so AppDelegate can swap in real closures after super.init().
    /// The closure values are forwarded to PanelRootView via NSHostingView's
    /// rootView, which is rebuilt only on first panel creation — so the
    /// initial reference here must be the final one. Setting `actions` after
    /// `showAlways()` has no effect.
    var actions: PanelActions
    private var panel: NSPanel?

    init(
        appState: AppState,
        recorder: AudioRecorder,
        transcriber: Transcriber,
        actions: PanelActions
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcriber = transcriber
        self.actions = actions
        super.init()
    }

    /// Show the pill on app launch. Always visible from this point on; the
    /// content reflects the active state via SwiftUI bindings.
    func showAlways() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionOnActiveScreen(panel)
        panel.orderFrontRegardless()
        // Reposition on screen changes (display arrangement, resolution).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                self?.positionOnActiveScreen(panel)
            }
        }
    }

    private func makePanel() -> NSPanel {
        let panel = NSPanel(
            contentRect: NSRect(origin: .zero, size: NSSize(width: Self.panelWidth, height: Self.panelHeight)),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.backgroundColor = .clear
        panel.isOpaque = false
        panel.hasShadow = false // SwiftUI Capsule provides its own shadow
        // Pill background is hardcoded to black (.black.opacity(0.82)), so
        // pin the panel's appearance to dark — otherwise SwiftUI's semantic
        // colors (.primary, .secondary, .tint, ...) resolve based on the
        // user's system Appearance setting, and Light-Mode Macs end up with
        // dark-gray text on a dark-gray pill (illegible). Forcing .darkAqua
        // here makes every machine render the pill identically.
        panel.appearance = NSAppearance(named: .darkAqua)
        panel.titlebarAppearsTransparent = true
        panel.titleVisibility = .hidden
        panel.standardWindowButton(.closeButton)?.isHidden = true
        panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
        panel.standardWindowButton(.zoomButton)?.isHidden = true
        panel.collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        panel.hidesOnDeactivate = false
        panel.ignoresMouseEvents = false
        panel.delegate = self

        // Let mouse events outside the pill pass through to whatever's behind.
        // The pill's own Capsule background catches clicks for buttons.
        let host = NSHostingView(
            rootView: PanelRootView(
                appState: appState,
                recorder: recorder,
                transcriber: transcriber,
                actions: actions
            )
        )
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        panel.contentView = host

        return panel
    }

    private func positionOnActiveScreen(_ panel: NSPanel) {
        guard let screen = NSScreen.main ?? panel.screen ?? NSScreen.screens.first else { return }
        let visible = screen.visibleFrame
        let size = panel.frame.size
        // Bottom-center: horizontally centered, anchored above the dock area.
        let origin = NSPoint(
            x: visible.midX - size.width / 2,
            y: visible.minY + Self.bottomInset
        )
        panel.setFrameOrigin(origin)
    }
}

extension PanelWindowController: NSWindowDelegate {
    // No-op — we never close the pill. Resize / move handled by SwiftUI.
}
