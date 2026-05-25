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
}
