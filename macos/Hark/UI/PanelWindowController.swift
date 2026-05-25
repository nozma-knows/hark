import AppKit
import Observation
import OSLog
import SwiftUI

private let panelLogger = Logger(subsystem: "co.milbo.hark", category: "PanelWindow")

/// Owns the always-visible Wispr Flow-style pill panel. The panel:
/// - is borderless + non-activating (clicks pass through outside the pill,
///   enforced by `PassThroughHostingView`'s hit-test override)
/// - floats above all standard windows on every Space
/// - doesn't take focus from the user's current app
/// - hosts a SwiftUI tree whose content size + horizontal alignment
///   reflect the active pill state and the user-chosen anchor
///
/// Position is governed by `PillPositionModel.anchor` (`.left`,
/// `.center`, `.right`), persisted per-display via `PillPositionStore`.
/// The panel is repositioned on launch, on screen-config changes, on
/// drag release, and on settings "Reset" actions.
@MainActor
final class PanelWindowController: NSObject {
    private static let panelHeight: CGFloat = 72
    private static let panelWidth: CGFloat = 680
    /// Vertical distance between the panel and the top of the Dock.
    /// Mirror of `PillPositionGeometry.bottomInset` — kept here as a
    /// named constant for clarity at the call site.
    private static let bottomInset: CGFloat = PillPositionGeometry.bottomInset

    private let appState: AppState
    private let recorder: AudioRecorder
    private let transcriber: Transcriber
    private let store: PillPositionStore
    let positionModel: PillPositionModel
    /// Mutable so AppDelegate can swap in real closures after super.init().
    /// The closure values are captured by reference inside `PanelRootView`
    /// through this controller; updates take effect on the next interaction.
    var actions: PanelActions {
        didSet { rebuildHostedRoot() }
    }

    private var panel: NSPanel?
    private var hostingView: PassThroughHostingView<PanelRootView>?
    /// Captured at the start of each drag so live `updateDrag` calls
    /// translate from a stable reference. Cleared on `endDrag`.
    private var dragStartOrigin: CGPoint?
    /// Local NSEvent monitor token for the ⌘+drag-anywhere shortcut.
    /// Held so `deinit` can tear it down. `nonisolated(unsafe)` mirrors
    /// the pattern used elsewhere (see AppDelegate.notificationTokens):
    /// deinit runs in a nonisolated context under Swift 6 strict
    /// concurrency and can't access @MainActor storage. Safe in
    /// practice: written only from MainActor during launch, read only
    /// from deinit at teardown.
    nonisolated(unsafe) private var commandDragMonitor: Any?
    /// While a ⌘+drag is in flight, holds the global mouse location at
    /// drag start. Non-nil means subsequent `.leftMouseDragged` /
    /// `.leftMouseUp` events on the panel belong to this drag and the
    /// monitor consumes them. Nil means no ⌘ drag is active and events
    /// pass through normally (SwiftUI's per-view DragGesture handles
    /// regular drags on the pill background).
    private var commandDragStart: CGPoint?

    init(
        appState: AppState,
        recorder: AudioRecorder,
        transcriber: Transcriber,
        actions: PanelActions,
        store: PillPositionStore = PillPositionStore()
    ) {
        self.appState = appState
        self.recorder = recorder
        self.transcriber = transcriber
        self.actions = actions
        self.store = store
        positionModel = PillPositionModel()
        super.init()
    }

    /// Show the pill on app launch. Always visible from this point on; the
    /// content reflects the active state via SwiftUI bindings.
    func showAlways() {
        let panel = panel ?? makePanel()
        self.panel = panel
        positionAtCurrentAnchor(panel)
        panel.orderFrontRegardless()
        installCommandDragMonitor()
        // Reposition on screen changes (display arrangement, resolution).
        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let panel = self?.panel else { return }
                self?.positionAtCurrentAnchor(panel)
            }
        }
    }

    deinit {
        if let token = commandDragMonitor {
            NSEvent.removeMonitor(token)
        }
    }

    /// Whether any display has a stored (non-default) anchor. Drives
    /// the "Reset all displays" disclosure in Settings — there's no
    /// reason to surface that option until at least one display has
    /// been customized.
    var hasAnyStoredAnchor: Bool { store.hasAnyStoredAnchor }

    /// Reset the pill to the default anchor on the currently active
    /// screen. Used by Settings → General → "Reset pill position."
    func resetPositionOnActiveScreen() {
        guard let panel else { return }
        guard let screen = activeScreen(for: panel) else { return }
        store.setAnchor(PillPositionStore.defaultAnchor, for: screen)
        positionModel.anchor = PillPositionStore.defaultAnchor
        animatePanelOrigin(panel, to: PillPositionGeometry.origin(
            for: PillPositionStore.defaultAnchor,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        ))
    }

    /// Reset the pill anchor on every display. Used by Settings →
    /// "Reset all displays" (only surfaced when multiple screens have
    /// stored anchors).
    func resetPositionOnAllScreens() {
        store.resetAll()
        guard let panel else { return }
        positionAtCurrentAnchor(panel)
    }

    // MARK: - Drag handlers (called by PanelActions)

    func beginDrag() {
        guard let panel else { return }
        dragStartOrigin = panel.frame.origin
        positionModel.isDragging = true
    }

    func updateDrag(translation: CGSize) {
        guard let panel, let start = dragStartOrigin else { return }
        guard let screen = activeScreen(for: panel) else { return }
        let target = PillPositionGeometry.snapped(
            x: start.x + translation.width,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        )
        panel.setFrameOrigin(NSPoint(x: target, y: start.y))
    }

    func endDrag(translation: CGSize) {
        defer {
            dragStartOrigin = nil
            positionModel.isDragging = false
        }
        guard let panel, let start = dragStartOrigin else { return }
        guard let screen = activeScreen(for: panel) else { return }
        let droppedX = PillPositionGeometry.clampX(
            start.x + translation.width,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        )
        let anchor = PillPositionGeometry.nearestAnchor(
            toX: droppedX,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        )
        store.setAnchor(anchor, for: screen)
        positionModel.anchor = anchor
        animatePanelOrigin(panel, to: PillPositionGeometry.origin(
            for: anchor,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        ))
    }

    // MARK: - Internals

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

        let host = PassThroughHostingView(rootView: makeRootView())
        host.wantsLayer = true
        host.layer?.backgroundColor = NSColor.clear.cgColor
        hostingView = host
        panel.contentView = host

        return panel
    }

    /// Builds the SwiftUI root view, capturing closures that update the
    /// hosting view's visible pill rect (for click-through hit testing).
    private func makeRootView() -> PanelRootView {
        PanelRootView(
            appState: appState,
            recorder: recorder,
            transcriber: transcriber,
            positionModel: positionModel,
            actions: actions,
            onPillBoundsChanged: { [weak self] rect in
                self?.hostingView?.visiblePillRect = rect
            }
        )
    }

    /// Re-create the hosting view's rootView whenever `actions` is
    /// reassigned. SwiftUI captures the original closures by value, so a
    /// late `panelController.actions = ...` from AppDelegate would
    /// otherwise call the placeholder closures forever.
    private func rebuildHostedRoot() {
        hostingView?.rootView = makeRootView()
    }

    // MARK: - ⌘+drag-anywhere monitor

    /// Install the local-app event monitor that handles `⌘+drag` on the
    /// pill. SwiftUI's per-view `DragGesture` covers the discoverable
    /// "drag the pill background" case; the monitor adds the
    /// power-user "⌘ + drag anywhere on the pill (including over
    /// buttons)" gesture by consuming mouse events at the NSEvent layer
    /// before SwiftUI's responder chain ever sees them.
    private func installCommandDragMonitor() {
        guard commandDragMonitor == nil else { return }
        commandDragMonitor = NSEvent.addLocalMonitorForEvents(
            matching: [.leftMouseDown, .leftMouseDragged, .leftMouseUp]
        ) { [weak self] event in
            guard let self else { return event }
            // NSEvent monitors are guaranteed by AppKit to fire on the
            // main thread, but NSEvent isn't Sendable in Swift 6's
            // strict mode. We can't hand the event itself across the
            // assumeIsolated boundary — but we *can* hand across a
            // Sendable snapshot of the fields we care about, and let
            // the handler return a verdict (consume vs. pass through).
            let snapshot = EventSnapshot(
                type: event.type,
                modifierFlags: event.modifierFlags,
                locationInWindow: event.locationInWindow,
                windowNumber: event.windowNumber,
                mouseLocation: NSEvent.mouseLocation
            )
            let consume = MainActor.assumeIsolated {
                self.handlePotentialCommandDrag(snapshot)
            }
            return consume ? nil : event
        }
    }

    /// Sendable carrier for the NSEvent fields the ⌘+drag handler
    /// needs. Built nonisolated from the raw NSEvent in the monitor
    /// closure, then passed across into the MainActor handler — this
    /// avoids handing the non-Sendable NSEvent itself across the
    /// concurrency boundary.
    private struct EventSnapshot {
        let type: NSEvent.EventType
        let modifierFlags: NSEvent.ModifierFlags
        let locationInWindow: CGPoint
        let windowNumber: Int
        let mouseLocation: CGPoint
    }

    /// Returns true if the event should be consumed (a ⌘+drag is
    /// active), false to let SwiftUI / the responder chain see it.
    private func handlePotentialCommandDrag(_ snapshot: EventSnapshot) -> Bool {
        guard let panel, snapshot.windowNumber == panel.windowNumber else { return false }

        switch snapshot.type {
        case .leftMouseDown:
            guard snapshot.modifierFlags.contains(.command), canDragPill else { return false }
            guard let host = hostingView else { return false }
            // Hit-test against the same rect the pass-through hosting
            // view uses, so ⌘+drag only kicks in when the cursor is
            // actually over the visible pill (not the transparent
            // surround).
            let pointInHost = host.convert(snapshot.locationInWindow, from: nil)
            let outset = PassThroughHostingView<PanelRootView>.hitTestOutset
            let target = host.visiblePillRect.insetBy(dx: -outset, dy: -outset)
            guard target.contains(pointInHost) else { return false }

            commandDragStart = snapshot.mouseLocation
            beginDrag()
            NSCursor.closedHand.push()
            return true

        case .leftMouseDragged:
            guard let start = commandDragStart else { return false }
            updateDrag(translation: CGSize(
                width: snapshot.mouseLocation.x - start.x,
                height: snapshot.mouseLocation.y - start.y
            ))
            return true

        case .leftMouseUp:
            guard let start = commandDragStart else { return false }
            endDrag(translation: CGSize(
                width: snapshot.mouseLocation.x - start.x,
                height: snapshot.mouseLocation.y - start.y
            ))
            commandDragStart = nil
            NSCursor.pop()
            return true

        default:
            return false
        }
    }

    /// True when the pill is in its `.idle` mode — same gate the
    /// SwiftUI drag modifier uses. Recording, processing, transcript,
    /// and command-result modes lock movement so the user can't fling
    /// the pill while reaching for stop / copy / dismiss.
    private var canDragPill: Bool {
        PanelViewModel.mode(
            recorderState: recorder.state,
            transcriberState: transcriber.state,
            isExecutingCommand: appState.isExecutingCommand,
            isPolishing: appState.isPolishing,
            commandResult: appState.commandResult,
            transcript: appState.transcript,
            loadingElapsedSeconds: nil
        ) == .idle
    }

    private func positionAtCurrentAnchor(_ panel: NSPanel) {
        guard let screen = activeScreen(for: panel) else { return }
        let anchor = store.anchor(for: screen)
        positionModel.anchor = anchor
        let origin = PillPositionGeometry.origin(
            for: anchor,
            visibleFrame: screen.visibleFrame,
            panelWidth: panel.frame.width
        )
        panel.setFrameOrigin(origin)
    }

    private func activeScreen(for panel: NSPanel) -> NSScreen? {
        NSScreen.main ?? panel.screen ?? NSScreen.screens.first
    }

    /// Animate the panel to the target origin with a snappy spring,
    /// keeping Y constant. Used on drag release and on "Reset position."
    private func animatePanelOrigin(_ panel: NSPanel, to origin: CGPoint) {
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.22
            context.timingFunction = CAMediaTimingFunction(name: .easeOut)
            panel.animator().setFrameOrigin(origin)
        }
    }
}

extension PanelWindowController: NSWindowDelegate {
    // No-op — we never close the pill. Resize / move handled by SwiftUI
    // and the drag callbacks above.
}
