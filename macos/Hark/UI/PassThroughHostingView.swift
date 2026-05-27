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
    /// The current visible-pill rect in this view's *local* coordinate
    /// space (flipped, Y-down top-left — matches `NSHostingView`'s
    /// bounds and SwiftUI's named coordinate space). Updated by
    /// `PanelRootView` as the pill grows / shrinks / re-aligns.
    /// Defaults to `.zero` so an uninitialised view passes every click
    /// through (correct fail-safe — the user can still click apps below
    /// even if the rect plumbing breaks).
    var visiblePillRect: CGRect = .zero

    /// Padding around `visiblePillRect` that still counts as a hit.
    /// Small but nonzero so the at-rest 40×3pt idle pill remains easy
    /// to mouse over.
    static var hitTestOutset: CGFloat { 4 }

    /// `NSView.hitTest(_:)` is documented as receiving `point` in the
    /// receiver's *superview* coordinate system — for a borderless
    /// panel that's the un-flipped frame view (Y-up bottom-left).
    /// `visiblePillRect` lives in our flipped local bounds (Y-down
    /// top-left, matching SwiftUI). Without converting between the two,
    /// every click on the pill — which sits at the bottom of the panel
    /// — lands at a small Y while the rect reports a large Y, and the
    /// gate vetoes the click. That swallows both button presses and the
    /// SwiftUI `DragGesture` on the pill background. Convert first,
    /// then compare.
    override func hitTest(_ point: NSPoint) -> NSView? {
        guard !visiblePillRect.isEmpty else { return nil }
        let local = localPoint(from: point)
        let target = visiblePillRect.insetBy(dx: -Self.hitTestOutset, dy: -Self.hitTestOutset)
        guard target.contains(local) else { return nil }
        return super.hitTest(point)
    }

    /// Convert a point received by `hitTest(_:)` (in the superview's
    /// coord system) into this view's local, flipped coord system.
    /// Falls back to the input unchanged when there's no superview —
    /// keeps unit tests that exercise the gate in isolation working
    /// without fabricating a window hierarchy.
    private func localPoint(from point: NSPoint) -> NSPoint {
        guard let superview else { return point }
        return convert(point, from: superview)
    }
}
