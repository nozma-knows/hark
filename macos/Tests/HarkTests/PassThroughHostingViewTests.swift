@testable import Hark
import SwiftUI
import XCTest

/// Hit-test gating for the floating pill panel. The hosting view must
/// return nil for any click outside the visible pill rect (so the click
/// passes through to the app underneath); inside the rect, super's
/// hit-test runs and returns whichever SwiftUI view claimed the point.
@MainActor
final class PassThroughHostingViewTests: XCTestCase {
    private func makeView() -> PassThroughHostingView<EmptyView> {
        let host = PassThroughHostingView(rootView: EmptyView())
        host.frame = CGRect(x: 0, y: 0, width: 200, height: 100)
        return host
    }

    func testEmptyRectPassesAllClicksThrough() {
        let host = makeView()
        host.visiblePillRect = .zero
        XCTAssertNil(host.hitTest(CGPoint(x: 100, y: 50)))
        XCTAssertNil(host.hitTest(CGPoint(x: 0, y: 0)))
    }

    func testOutsideRectReturnsNil() {
        let host = makeView()
        host.visiblePillRect = CGRect(x: 80, y: 20, width: 40, height: 24)
        // Well outside on every side.
        XCTAssertNil(host.hitTest(CGPoint(x: 10, y: 10)))
        XCTAssertNil(host.hitTest(CGPoint(x: 190, y: 90)))
        XCTAssertNil(host.hitTest(CGPoint(x: 100, y: 0)))
        XCTAssertNil(host.hitTest(CGPoint(x: 100, y: 80)))
    }

    func testInsideRectDelegatesToSuper() {
        let host = makeView()
        let rect = CGRect(x: 80, y: 20, width: 40, height: 24)
        host.visiblePillRect = rect
        // Inside the gate, the call delegates to NSHostingView's
        // hitTest. With an EmptyView root, NSHostingView returns
        // itself as the catch-all hit target — what matters for
        // click-through is that the gate does NOT veto the hit.
        XCTAssertNotNil(host.hitTest(CGPoint(x: rect.midX, y: rect.midY)))
    }

    func testHitTestOutsetExtendsHittableArea() {
        let host = makeView()
        let rect = CGRect(x: 80, y: 20, width: 40, height: 24)
        host.visiblePillRect = rect
        let outset = PassThroughHostingView<EmptyView>.hitTestOutset
        // Just outside the inner rect but within the outset margin —
        // should still hit (gate uses the outset rect).
        let edgePoint = CGPoint(x: rect.maxX + outset - 0.5, y: rect.midY)
        XCTAssertNotNil(host.hitTest(edgePoint))
        // A point past the outset margin: gate must reject.
        let outsideOutset = CGPoint(x: rect.maxX + outset + 1, y: rect.midY)
        XCTAssertNil(host.hitTest(outsideOutset))
    }

    /// Regression test for the coord-system mismatch that broke pill
    /// buttons + drag in the wild: `hitTest(_:)` receives the point in
    /// the SUPERVIEW's coords (Y-up bottom-left for a borderless panel's
    /// frame view), but `visiblePillRect` lives in the flipped local
    /// bounds (Y-down top-left, matching SwiftUI). Without conversion,
    /// a click on the visually-bottom pill arrives with small Y and the
    /// rect reports large Y — every click is silently dropped.
    ///
    /// Reproduce the production hierarchy: borderless panel with the
    /// hosting view as contentView, then call hitTest with a point in
    /// the panel's (un-flipped) coords that should land inside a rect
    /// expressed in the host's (flipped) local coords.
    func testHitTestConvertsSuperviewCoordsToLocal() {
        let panel = NSPanel(
            contentRect: NSRect(x: 0, y: 0, width: 680, height: 72),
            styleMask: [.borderless, .nonactivatingPanel, .fullSizeContentView],
            backing: .buffered,
            defer: false
        )
        let host = PassThroughHostingView(rootView: EmptyView())
        panel.contentView = host
        // Pill rendered at the bottom of the panel — in flipped local
        // coords that's a large Y (near host.bounds.maxY).
        let rect = CGRect(x: 300, y: 42, width: 80, height: 24)
        host.visiblePillRect = rect

        // A click at the bottom of the panel, in the frame view's Y-up
        // coords (the coord system hitTest receives points in). Y = 12
        // corresponds to the vertical center of the pill once flipped.
        let clickAtBottomInSuperviewCoords = NSPoint(x: 340, y: 12)
        XCTAssertNotNil(host.hitTest(clickAtBottomInSuperviewCoords))

        // A click at the TOP of the panel (well above the pill) must
        // still be rejected — in Y-up coords that's a large Y, which
        // corresponds to a small Y in flipped local coords (above the
        // rect). The bug would have inverted this.
        let clickAtTopInSuperviewCoords = NSPoint(x: 340, y: 68)
        XCTAssertNil(host.hitTest(clickAtTopInSuperviewCoords))
    }
}
