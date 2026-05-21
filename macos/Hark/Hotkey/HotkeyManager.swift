import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Which gesture the user initiated. The active trigger is updated live
/// while Fn is held — adding or releasing modifiers updates the trigger
/// in real time. The value at the moment Fn is released is what
/// AppDelegate uses to route the transcript.
///
/// Modifier precedence at Fn-up time:
///   Shift held   → `.command`  (voice command; transcript drives Bash)
///   Control held → `.insert`   (paste polished transcript into focused input)
///   neither      → `.dictate`  (show polished transcript in pill)
enum HotkeyTrigger: Equatable {
    /// Plain Fn — polished transcript goes into the pill UI.
    case dictate
    /// Fn + Control — polished transcript gets pasted into the focused text input.
    case insert
    /// Fn + Shift — transcript becomes a voice command Claude executes via Bash.
    case command
}

/// How the global modifier-only hotkey behaves. Persisted to UserDefaults.
enum HotkeyMode: String, CaseIterable, Identifiable {
    case hold
    case toggle

    var id: Self { self }

    var label: String {
        switch self {
        case .hold: "Hold to talk"
        case .toggle: "Toggle"
        }
    }

    var detail: String {
        switch self {
        case .hold: "Recording while the key is held. Release to stop."
        case .toggle: "Tap the key once to start, tap again to stop."
        }
    }
}

/// Detects the Fn (globe) key via a CGEvent tap. Watches *all* flagsChanged
/// events (not just keycode 63) so Ctrl transitions during a held Fn
/// session can flip the trigger between `.dictate` and `.insert` in real
/// time. Requires Accessibility permission.
@MainActor
@Observable
final class HotkeyManager {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "HotkeyManager")
    private static let modeDefaultsKey = "co.milbo.hark.hotkey.mode"
    /// kVK_Function from `<HIToolbox/Events.h>`.
    private static let fnKeycode: Int64 = 63

    var mode: HotkeyMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        }
    }

    let label = "Fn"

    @ObservationIgnored var onKeyDown: ((HotkeyTrigger) -> Void)?
    @ObservationIgnored var onKeyUp: ((HotkeyTrigger) -> Void)?

    /// Live trigger value. Updated whenever Ctrl state changes during a
    /// held Fn session. Observable so the panel could surface "paste mode"
    /// in real time (future enhancement).
    private(set) var currentTrigger: HotkeyTrigger = .dictate

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var isHeld = false

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        mode = stored.flatMap(HotkeyMode.init(rawValue:)) ?? .hold
        installEventTap()
    }

    private func installEventTap() {
        let mask: CGEventMask = 1 << CGEventType.flagsChanged.rawValue
        let userInfo = Unmanaged.passUnretained(self).toOpaque()

        let callback: CGEventTapCallBack = { _, type, event, info in
            guard type == .flagsChanged, let info else {
                return Unmanaged.passUnretained(event)
            }
            // Look at EVERY flagsChanged event — not just keycode 63. Ctrl
            // press/release events have keycodes 59 (left) or 62 (right);
            // we need to see them so we can re-evaluate the trigger when
            // the user adds Ctrl mid-Fn-hold.
            let flags = event.flags
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            // swiftlint:disable:next prefer_self_in_static_references
            let isFnEvent = keycode == HotkeyManager.fnKeycode
            let isFnDown = flags.contains(.maskSecondaryFn)
            let isCtrlDown = flags.contains(.maskControl)
            let isShiftDown = flags.contains(.maskShift)
            let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in
                manager.update(
                    isFnEvent: isFnEvent,
                    fnDown: isFnDown,
                    ctrlDown: isCtrlDown,
                    shiftDown: isShiftDown
                )
            }
            return Unmanaged.passUnretained(event)
        }

        guard
            let tap = CGEvent.tapCreate(
                tap: .cgSessionEventTap,
                place: .headInsertEventTap,
                options: .listenOnly,
                eventsOfInterest: mask,
                callback: callback,
                userInfo: userInfo
            ) else
        {
            Self.logger.error("Failed to create CGEvent tap — Accessibility permission?")
            return
        }

        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)

        eventTap = tap
        runLoopSource = source
        Self.logger.info("Fn event tap installed")
    }

    private func update(isFnEvent: Bool, fnDown: Bool, ctrlDown: Bool, shiftDown: Bool) {
        // Latch-upgrade: while Fn is held, the trigger can only escalate
        // (.dictate → .insert → .command), never downgrade. Users routinely
        // release Shift / Ctrl a moment before they release Fn — without
        // latching that brief gap would silently demote the gesture.
        if isHeld, mode == .hold {
            let observed = Self.resolveTrigger(ctrlDown: ctrlDown, shiftDown: shiftDown)
            if Self.priority(observed) > Self.priority(currentTrigger) {
                let desc = String(describing: observed)
                Self.logger.info("Trigger upgrade: \(desc, privacy: .public) (ctrl=\(ctrlDown), shift=\(shiftDown))")
                currentTrigger = observed
            }
        }

        // Only Fn key transitions start/stop a session.
        guard isFnEvent else { return }

        if fnDown, !isHeld {
            isHeld = true
            currentTrigger = Self.resolveTrigger(ctrlDown: ctrlDown, shiftDown: shiftDown)
            let triggerDesc = String(describing: currentTrigger)
            Self.logger.info("Fn down → \(triggerDesc, privacy: .public) (ctrl=\(ctrlDown), shift=\(shiftDown))")
            onKeyDown?(currentTrigger)
        } else if !fnDown, isHeld {
            isHeld = false
            let triggerDesc = String(describing: currentTrigger)
            Self.logger.info("Fn up → \(triggerDesc, privacy: .public) (ctrl=\(ctrlDown), shift=\(shiftDown))")
            onKeyUp?(currentTrigger)
        }
    }

    /// Modifier-to-trigger map. Shift wins over Ctrl if both are held — the
    /// reasoning is that ".command" is the more deliberate / rarer gesture,
    /// so a user who's holding both probably meant to engage it.
    private static func resolveTrigger(ctrlDown: Bool, shiftDown: Bool) -> HotkeyTrigger {
        if shiftDown { return .command }
        if ctrlDown { return .insert }
        return .dictate
    }

    /// Power ranking of triggers — used by the latch-upgrade rule so the
    /// gesture can only escalate (dictate → insert → command), never demote.
    private static func priority(_ trigger: HotkeyTrigger) -> Int {
        switch trigger {
        case .dictate: 0
        case .insert: 1
        case .command: 2
        }
    }
}
