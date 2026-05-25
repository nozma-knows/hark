import Foundation
@testable import Hark
import XCTest

final class PolishProfileTests: XCTestCase {
    /// PolishProfileStore reads/writes `UserDefaults.standard` under a
    /// fixed key. Tests share the same standard defaults, so we clear
    /// the key before each test to start from a known empty state.
    /// `Self.defaultsKey` mirrors the private constant in the store.
    private static let defaultsKey = "co.milbo.hark.polishProfiles"

    override func setUp() {
        super.setUp()
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
    }

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: Self.defaultsKey)
        super.tearDown()
    }

    // MARK: - Resolution

    @MainActor
    func test_profile_fallsBackToDefaultWhenNoOverride() {
        let store = PolishProfileStore()
        store.setDefault(.casual)
        XCTAssertEqual(store.profile(forBundleID: "com.unknown.app"), .casual)
    }

    @MainActor
    func test_profile_usesOverrideWhenPresent() {
        let store = PolishProfileStore()
        store.setDefault(.standard)
        store.setOverride(.code, for: "com.apple.dt.Xcode")
        XCTAssertEqual(store.profile(forBundleID: "com.apple.dt.Xcode"), .code)
    }

    @MainActor
    func test_profile_nilBundleIDHitsDefault() {
        let store = PolishProfileStore()
        store.setDefault(.formal)
        XCTAssertEqual(store.profile(forBundleID: nil), .formal)
    }

    @MainActor
    func test_profile_emptyBundleIDHitsDefault() {
        let store = PolishProfileStore()
        store.setDefault(.formal)
        XCTAssertEqual(store.profile(forBundleID: ""), .formal)
    }

    // MARK: - Mutation

    @MainActor
    func test_setOverride_persistsAcrossInstances() {
        let store = PolishProfileStore()
        store.setOverride(.casual, for: "com.tinyspeck.slackmacgap")
        // Recreating the store re-reads UserDefaults; the override
        // should survive.
        let reloaded = PolishProfileStore()
        XCTAssertEqual(reloaded.profile(forBundleID: "com.tinyspeck.slackmacgap"), .casual)
    }

    @MainActor
    func test_setOverride_nilRemovesEntry() {
        let store = PolishProfileStore()
        store.setOverride(.code, for: "com.apple.dt.Xcode")
        XCTAssertEqual(store.profile(forBundleID: "com.apple.dt.Xcode"), .code)
        store.setOverride(nil, for: "com.apple.dt.Xcode")
        // Default reasserts itself.
        XCTAssertEqual(store.profile(forBundleID: "com.apple.dt.Xcode"), store.defaultProfile)
    }

    @MainActor
    func test_setOverride_ignoresWhitespaceBundleID() {
        let store = PolishProfileStore()
        store.setOverride(.code, for: "   ")
        XCTAssertTrue(store.sortedOverrides.isEmpty)
    }

    @MainActor
    func test_sortedOverrides_ascending() {
        let store = PolishProfileStore()
        store.setOverride(.code, for: "com.zulu.app")
        store.setOverride(.casual, for: "com.alpha.app")
        store.setOverride(.formal, for: "com.mike.app")
        XCTAssertEqual(
            store.sortedOverrides.map(\.bundleID),
            ["com.alpha.app", "com.mike.app", "com.zulu.app"]
        )
    }
}
