import AppKit
import SwiftUI

/// `NSHostingView` subclass that confines mouse hit-testing to a single
/// caller-supplied rect (`visiblePillRect`). Points outside that rect
/// return `nil` from `hitTest(_:)`, so the window manager treats the
/// click as unclaimed and forwards it to the next window underneath —
/// true click-through for the transparent surround.
///
/// Why: `PanelWindowController` uses a generously sized panel (a few
/// hundred points wide) so wide pill states (transcript, command result)
/// have room to render without resizing the underlying NSPanel between
/// every state transition. Without this subclass the panel's empty
/// stage swallows every click that lands in its frame, even where no
/// SwiftUI content is visible.
///
/// The rect is updated by `PanelRootView` via a `PreferenceKey` that
/// tracks the active pill's bounds in the panel's coordinate space. A
/// small outset (`hitTestOutset`) keeps the 40×3pt idle pill grabbable
/// — the visible target is tiny and benefits from a slightly larger
/// hit area, but the outset is small enough that perceived click-through
/// is preserved.
@MainActor
final class PassThroughHostingView<Content: View>: NSHostingView<Content> {
    /// The current visible-pill rect in this view's coordinate space.
    /// Updated by SwiftUI as the pill grows / shrinks / re-aligns.
    /// Defaults to `.zero` so an uninitialised view passes every click
    /// through (correct fail-safe — the user can still click apps below
    /// even if the rect plumbing breaks).
    var visiblePillRect: CGRect = .zero

    /// Padding around `visiblePillRect` that still counts as a hit.
    /// Small but nonzero so the at-rest 40×3pt idle pill remains easy
    /// to mouse over.
    static var hitTestOutset: CGFloat { 4 }

    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !visiblePillRect.isEmpty else { return nil }
        let target = visiblePillRect.insetBy(dx: -Self.hitTestOutset, dy: -Self.hitTestOutset)
        guard target.contains(point) else { return nil }
        return super.hitTest(point)
    }

    /// Deliver the very first click straight to the pill's buttons.
    ///
    /// The pill lives in a non-activating `NSPanel` (see
    /// `PanelWindowController`), so Hark is essentially never the active
    /// app or key window — the user is always clicking in from some other
    /// foreground app. By default AppKit treats a click into an inactive
    /// window as an *activation* click: it makes the window key and
    /// swallows the event instead of routing it to the view underneath.
    /// That's the "hover works but the record / settings buttons don't
    /// respond" bug — hover uses tracking areas (no key-window
    /// requirement) while clicks were being eaten by the activation step.
    ///
    /// Returning `true` here delivers the mouseDown directly to the
    /// SwiftUI content on the first click, without stealing focus from the
    /// user's current app — preserving the non-activating behavior.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }
}
