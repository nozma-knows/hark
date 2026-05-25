@testable import Hark
import XCTest

/// `PillPositionStore` is the only thing standing between "I set the
/// pill to the left" and "next launch puts it back at center." These
/// tests pin down the persistence behavior using an isolated
/// `UserDefaults(suiteName:)` so we don't pollute the user's real
/// preferences when running the test suite.
@MainActor
final class PillPositionStoreTests: XCTestCase {
    private var defaults: UserDefaults!
    private var suiteName: String!

    override func setUp() {
        super.setUp()
        suiteName = "co.milbo.hark.tests.pillStore.\(UUID().uuidString)"
        defaults = UserDefaults(suiteName: suiteName)
    }

    override func tearDown() {
        defaults.removePersistentDomain(forName: suiteName)
        defaults = nil
        suiteName = nil
        super.tearDown()
    }

    func testDefaultIsCenterForUnknownScreen() {
        let store = PillPositionStore(defaults: defaults)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-A"), .center)
    }

    func testRoundTripPersistsEachAnchor() {
        let store = PillPositionStore(defaults: defaults)
        for anchor in PillAnchor.allCases {
            store.setAnchor(anchor, forScreenUUID: "screen-A")
            XCTAssertEqual(store.anchor(forScreenUUID: "screen-A"), anchor)
        }
    }

    func testPerScreenStorageIsIndependent() {
        let store = PillPositionStore(defaults: defaults)
        store.setAnchor(.left, forScreenUUID: "screen-A")
        store.setAnchor(.right, forScreenUUID: "screen-B")
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-A"), .left)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-B"), .right)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-C"), .center)
    }

    func testResetAllClearsEveryStoredAnchor() {
        let store = PillPositionStore(defaults: defaults)
        store.setAnchor(.left, forScreenUUID: "screen-A")
        store.setAnchor(.right, forScreenUUID: "screen-B")
        XCTAssertTrue(store.hasAnyStoredAnchor)
        store.resetAll()
        XCTAssertFalse(store.hasAnyStoredAnchor)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-A"), .center)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-B"), .center)
    }

    func testCorruptValueFallsBackToDefault() {
        // A value written by an older app version or hand-tweaked in
        // defaults should not crash the store; it should silently
        // default back to `.center`.
        defaults.set("nonsense", forKey: "co.milbo.hark.pillAnchor.screen-A")
        let store = PillPositionStore(defaults: defaults)
        XCTAssertEqual(store.anchor(forScreenUUID: "screen-A"), .center)
    }
}
