import AppKit
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
        DispatchQueue.main.asyncAfter(deadline: .now() + restoreDelay) {
            // If something else has overwritten the pasteboard in the meantime,
            // don't clobber it.
            if pasteboard.string(forType: .string) == text {
                pasteboard.clearContents()
                if let previousString {
                    pasteboard.setString(previousString, forType: .string)
                }
            }
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
