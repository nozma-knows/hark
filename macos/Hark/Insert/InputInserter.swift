// AppKit's NSPasteboard isn't `Sendable` in Swift 6 strict mode, but we
// always touch the singleton from MainActor (or via DispatchQueue.main
// in the restore-after-delay path, which IS MainActor). `@preconcurrency`
// silences the cross-module warning without changing our guarantees.
@preconcurrency import AppKit
import ApplicationServices
import CoreGraphics
import OSLog

/// Helpers for the "Fn + Ctrl → paste into focused input" flow.
///
/// Uses the system clipboard + a synthesized ⌘V keystroke for insertion —
/// this is the most reliable approach across Mac apps (TextEdit, browsers,
/// Slack, anything that accepts paste). The previous clipboard contents
/// are restored after a short delay so the user doesn't lose what they
/// had copied.
///
/// `hasFocusedTextInput()` queries Accessibility to see if the
/// system-wide focused element is a text-y role (TextField, TextArea,
/// ComboBox, SearchField). Requires AX permission (Hark already needs
/// this for the global hotkey, so we don't add a new prompt).
enum InputInserter {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "InputInserter")

    /// SF Symbols-style roles that we'll treat as "user is in a text input".
    private static let textInputRoles: Set<String> = [
        kAXTextFieldRole as String,
        kAXTextAreaRole as String,
        kAXComboBoxRole as String,
        "AXSearchField"
    ]

    /// Does the system-wide focused UI element accept text input?
    static func hasFocusedTextInput() -> Bool {
        let systemWide = AXUIElementCreateSystemWide()
        var focused: CFTypeRef?
        let getFocused = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedUIElementAttribute as CFString,
            &focused
        )
        guard getFocused == .success, let element = focused else {
            return false
        }
        // Safe-cast: AXFocusedUIElement returns an AXUIElement.
        // swiftlint:disable:next force_cast
        let axElement = element as! AXUIElement

        var roleValue: CFTypeRef?
        let getRole = AXUIElementCopyAttributeValue(
            axElement,
            kAXRoleAttribute as CFString,
            &roleValue
        )
        guard getRole == .success, let role = roleValue as? String else {
            return false
        }
        return textInputRoles.contains(role)
    }

    /// Place `text` on the clipboard and post ⌘V to the frontmost app.
    /// Restores the previous clipboard contents after `restoreDelay` so the
    /// dictated text doesn't replace what the user had copied earlier.
    static func paste(_ text: String, restoreDelay: TimeInterval = 1.5) {
        let pasteboard = NSPasteboard.general
        let previousString = pasteboard.string(forType: .string)

        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)

        postCommandV()

        // Restore prior clipboard after the paste has had time to land.
        // The closure passed to `asyncAfter` is treated as `@Sendable`, so
        // we capture `pasteboard` through a SendableBox — NSPasteboard
        // itself isn't Sendable, but accessing the shared `general`
        // singleton from the main queue is always safe.
        let pasteboardBox = PasteboardBox(pasteboard)
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            let pb = pasteboardBox.value
            // If something else has overwritten the pasteboard in the
            // meantime, don't clobber it.
            if pb.string(forType: .string) == text {
                pb.clearContents()
                if let previousString {
                    pb.setString(previousString, forType: .string)
                }
            }
        }
    }

    /// Carries the (non-Sendable) NSPasteboard reference into the
    /// `@Sendable` `asyncAfter` closure.
    ///
    /// Threading / lifetime contract:
    ///   - We only ever box `NSPasteboard.general`, a process-wide
    ///     singleton — never a per-call instance — so the boxed
    ///     reference never dangles.
    ///   - The closure that reads it runs on `DispatchQueue.main` (i.e.
    ///     the main thread), and the production call site of `paste(_:)`
    ///     is itself main-thread (called from `RecordingOrchestrator` on
    ///     MainActor). So both writers and the deferred reader are
    ///     serialized on the same thread.
    ///   - `@unchecked Sendable` only satisfies Swift 6's static checker
    ///     for the `asyncAfter` closure signature; it doesn't reflect
    ///     any real cross-thread sharing.
    private struct PasteboardBox: @unchecked Sendable {
        let value: NSPasteboard
        init(_ value: NSPasteboard) {
            self.value = value
        }
    }

    /// Synthesize ⌘V at the HID layer so the focused app sees a real paste
    /// keystroke.
    private static func postCommandV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        let cmdKey: CGKeyCode = 0x37 // kVK_Command
        let vKey: CGKeyCode = 0x09 // kVK_ANSI_V

        guard
            let cmdDown = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: true),
            let vDown = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: true),
            let vUp = CGEvent(keyboardEventSource: source, virtualKey: vKey, keyDown: false),
            let cmdUp = CGEvent(keyboardEventSource: source, virtualKey: cmdKey, keyDown: false) else
        {
            Self.logger.error("Failed to construct ⌘V CGEvents")
            return
        }
        vDown.flags = .maskCommand
        vUp.flags = .maskCommand

        cmdDown.post(tap: .cgAnnotatedSessionEventTap)
        vDown.post(tap: .cgAnnotatedSessionEventTap)
        vUp.post(tap: .cgAnnotatedSessionEventTap)
        cmdUp.post(tap: .cgAnnotatedSessionEventTap)
    }
}
