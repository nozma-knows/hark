@testable import Hark
import XCTest

/// `AppDelegate.indexOfSettingsWindow(in:)` is the recognition rule for
/// finding an existing Settings window to re-focus, rather than letting
/// SwiftUI's `sendAction(showSettingsWindow:)` spawn a duplicate.
///
/// The matching has to be loose because SwiftUI's actual window
/// identifier has varied across Xcode releases — sometimes "Settings",
/// sometimes "PreferenceWindow", occasionally nil — and the title
/// localizes. So we check both identifier and title, contains-match
/// against several spellings.
final class AppDelegateSettingsRecognitionTests: XCTestCase {
    typealias Window = AppDelegate.WindowDescriptor

    // MARK: - Positive matches

    func testIdentifierContainsSettingsMatches() {
        let windows = [Window(identifier: "Settings", title: "Hark", isVisible: true)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    func testIdentifierMixedCaseMatches() {
        let windows = [Window(identifier: "MyAppSettings", title: "Other", isVisible: true)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    func testTitleSettingsMatchesEvenWithoutIdentifier() {
        let windows = [Window(identifier: nil, title: "Settings", isVisible: true)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    func testIdentifierPreferencesMatches() {
        // The contains-check looks for "preferences" — with the trailing
        // s — so "PreferencesPanel" matches but "PreferenceWindow"
        // (singular) wouldn't. SwiftUI uses the plural form.
        let windows = [Window(identifier: "PreferencesPanel", title: "Hark", isVisible: true)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    func testTitlePreferencesMatches() {
        let windows = [Window(identifier: nil, title: "Preferences", isVisible: true)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    func testHiddenSettingsWindowStillMatches() {
        // Settings window may be backed by an existing-but-hidden NSWindow
        // (SwiftUI hides instead of disposing). We should still re-focus it.
        let windows = [Window(identifier: "Settings", title: "Settings", isVisible: false)]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    // MARK: - First match wins

    /// Multiple matching windows is theoretically possible if a previous
    /// crash left orphan windows. Re-focus the first one — predictable
    /// behavior beats guessing which is "real."
    func testReturnsFirstMatchingIndex() {
        let windows = [
            Window(identifier: "Settings", title: "Hark", isVisible: true),
            Window(identifier: "Settings", title: "Hark", isVisible: true)
        ]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 0)
    }

    /// Pill window or onboarding window before the settings window —
    /// return the settings window's correct index, not 0.
    func testSkipsNonMatchingToFindSettings() {
        let windows = [
            Window(identifier: "PillPanel", title: "", isVisible: true),
            Window(identifier: "Onboarding", title: "Welcome", isVisible: true),
            Window(identifier: "Settings", title: "Settings", isVisible: false)
        ]
        XCTAssertEqual(AppDelegate.indexOfSettingsWindow(in: windows), 2)
    }

    // MARK: - Negative matches

    func testEmptyArrayReturnsNil() {
        XCTAssertNil(AppDelegate.indexOfSettingsWindow(in: []))
    }

    func testOnlyNonMatchingWindowsReturnsNil() {
        let windows = [
            Window(identifier: "PillPanel", title: "", isVisible: true),
            Window(identifier: "Onboarding", title: "Welcome to Hark", isVisible: false)
        ]
        XCTAssertNil(AppDelegate.indexOfSettingsWindow(in: windows))
    }

    /// Title "Welcome to Hark" mustn't match — would mis-fire onto the
    /// onboarding window.
    func testTitleContainingSettingsAsSubstringDoesNotMatch() {
        // Only EXACT title match for "settings" should win — "MySettings
        // for App" shouldn't, since the identifier path is the
        // contains-match. We're verifying the title path is strict.
        let windows = [Window(identifier: "Onboarding", title: "MySettings for App", isVisible: true)]
        XCTAssertNil(AppDelegate.indexOfSettingsWindow(in: windows))
    }

    /// nil identifier + non-settings title → no match. Defends against
    /// a NULL identifier accidentally matching the contains check via
    /// empty-string short-circuit.
    func testNilIdentifierAndNonSettingsTitleReturnsNil() {
        let windows = [Window(identifier: nil, title: "Untitled Window", isVisible: true)]
        XCTAssertNil(AppDelegate.indexOfSettingsWindow(in: windows))
    }
}
