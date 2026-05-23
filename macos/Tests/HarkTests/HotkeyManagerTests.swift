@testable import Hark
import XCTest

/// `HotkeyManager.resolveTrigger` is the modifier truth table the whole
/// hotkey UX hangs on. Shift+Fn = .command, Ctrl+Fn = .insert, bare Fn =
/// .dictate, Shift+Ctrl+Fn = .command (Shift wins). Locking this in tests
/// prevents a future "let's tweak modifiers" commit from silently
/// swapping the dictate/insert mapping and breaking every existing
/// user's muscle memory.
final class HotkeyManagerTests: XCTestCase {
    // MARK: - resolveTrigger

    func testBareFnIsDictate() {
        XCTAssertEqual(
            HotkeyManager.resolveTrigger(ctrlDown: false, shiftDown: false),
            .dictate
        )
    }

    func testCtrlFnIsInsert() {
        XCTAssertEqual(
            HotkeyManager.resolveTrigger(ctrlDown: true, shiftDown: false),
            .insert
        )
    }

    func testShiftFnIsCommand() {
        XCTAssertEqual(
            HotkeyManager.resolveTrigger(ctrlDown: false, shiftDown: true),
            .command
        )
    }

    /// Shift+Ctrl+Fn — Shift wins. Documented preference: command is the
    /// rarer, more deliberate gesture, so we resolve up.
    func testShiftBeatsCtrl() {
        XCTAssertEqual(
            HotkeyManager.resolveTrigger(ctrlDown: true, shiftDown: true),
            .command
        )
    }

    // MARK: - priority (latch-upgrade ordering)

    func testPriorityOrdering() {
        // The latch-upgrade invariant: dictate < insert < command. Adding
        // a modifier mid-press can only escalate, never demote.
        XCTAssertLessThan(
            HotkeyManager.priority(.dictate),
            HotkeyManager.priority(.insert)
        )
        XCTAssertLessThan(
            HotkeyManager.priority(.insert),
            HotkeyManager.priority(.command)
        )
        XCTAssertLessThan(
            HotkeyManager.priority(.dictate),
            HotkeyManager.priority(.command)
        )
    }

    /// Convenience: every trigger has a distinct priority. If a future
    /// commit accidentally collapses two cases, the latch logic in
    /// `update()` breaks subtly (an upgrade from .insert to .insert is
    /// "no upgrade"), so guard the property explicitly.
    func testPrioritiesAreUnique() {
        let all: [HotkeyTrigger] = [.dictate, .insert, .command]
        let priorities = Set(all.map(HotkeyManager.priority))
        XCTAssertEqual(priorities.count, all.count)
    }
}
