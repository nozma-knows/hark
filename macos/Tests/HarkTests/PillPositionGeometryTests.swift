@testable import Hark
import XCTest

/// Pure geometry for the pill panel. Origin computation, drag-time
/// clamping, and snap-to-nearest are all tested here without an
/// NSScreen or NSPanel — feed in a `visibleFrame` and assert.
@MainActor
final class PillPositionGeometryTests: XCTestCase {
    private let visible = CGRect(x: 0, y: 0, width: 1440, height: 900)
    private let panelWidth: CGFloat = 680

    // MARK: - Origin

    func testOriginLeftSitsAtLeftEdgePlusInset() {
        let origin = PillPositionGeometry.origin(
            for: .left,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(origin.x, visible.minX + PillPositionGeometry.edgeInset)
        XCTAssertEqual(origin.y, visible.minY + PillPositionGeometry.bottomInset)
    }

    func testOriginCenterIsMathematicallyCentered() {
        let origin = PillPositionGeometry.origin(
            for: .center,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(origin.x, visible.midX - panelWidth / 2)
    }

    func testOriginRightSitsAtRightEdgeMinusInset() {
        let origin = PillPositionGeometry.origin(
            for: .right,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(origin.x, visible.maxX - panelWidth - PillPositionGeometry.edgeInset)
    }

    func testOriginHonorsNonZeroVisibleFrameOrigin() {
        // External display starting at x=1440 (right of the main
        // screen) and a Y offset (notched MacBook keeps the menu bar
        // out of visibleFrame).
        let offset = CGRect(x: 1440, y: 24, width: 1920, height: 1080)
        let origin = PillPositionGeometry.origin(
            for: .left,
            visibleFrame: offset,
            panelWidth: panelWidth
        )
        XCTAssertEqual(origin.x, offset.minX + PillPositionGeometry.edgeInset)
        XCTAssertEqual(origin.y, offset.minY + PillPositionGeometry.bottomInset)
    }

    // MARK: - Clamp

    func testClampAllowsXInsideBounds() {
        let clamped = PillPositionGeometry.clampX(
            500,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(clamped, 500)
    }

    func testClampPushesBackPastLeftEdge() {
        let clamped = PillPositionGeometry.clampX(
            -500,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(clamped, visible.minX + PillPositionGeometry.edgeInset)
    }

    func testClampPushesBackPastRightEdge() {
        let clamped = PillPositionGeometry.clampX(
            5000,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(clamped, visible.maxX - panelWidth - PillPositionGeometry.edgeInset)
    }

    // MARK: - Snap

    func testSnapPullsTowardNearestAnchorWithinRange() {
        let centerX = PillPositionGeometry.origin(
            for: .center,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x
        // 30pt off center — well within the 50pt snap zone.
        let result = PillPositionGeometry.snapped(
            x: centerX + 30,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(result, centerX)
    }

    func testSnapLeavesXAloneOutsideRange() {
        let centerX = PillPositionGeometry.origin(
            for: .center,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x
        let leftX = PillPositionGeometry.origin(
            for: .left,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x
        // Far from every anchor — sit between left and center, well
        // beyond either's snap zone.
        let midwayX = (leftX + centerX) / 2
        let result = PillPositionGeometry.snapped(
            x: midwayX,
            visibleFrame: visible,
            panelWidth: panelWidth
        )
        XCTAssertEqual(result, midwayX, accuracy: 0.001)
    }

    // MARK: - Nearest anchor

    func testNearestAnchorPicksClosestByDistance() {
        let leftX = PillPositionGeometry.origin(
            for: .left,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x
        let centerX = PillPositionGeometry.origin(
            for: .center,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x
        let rightX = PillPositionGeometry.origin(
            for: .right,
            visibleFrame: visible,
            panelWidth: panelWidth
        ).x

        // Within 10pt of each anchor → that anchor wins.
        XCTAssertEqual(
            PillPositionGeometry.nearestAnchor(
                toX: leftX + 10,
                visibleFrame: visible,
                panelWidth: panelWidth
            ),
            .left
        )
        XCTAssertEqual(
            PillPositionGeometry.nearestAnchor(
                toX: centerX - 5,
                visibleFrame: visible,
                panelWidth: panelWidth
            ),
            .center
        )
        XCTAssertEqual(
            PillPositionGeometry.nearestAnchor(
                toX: rightX - 20,
                visibleFrame: visible,
                panelWidth: panelWidth
            ),
            .right
        )
    }
}
