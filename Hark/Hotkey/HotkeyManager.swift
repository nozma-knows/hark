import AppKit
import CoreGraphics
import Foundation
import Observation
import OSLog

/// Which gesture the user initiated. Locked in at the moment Fn goes down
/// and held for the matching Fn-up so the AppDelegate knows where to send
/// the transcript when recording ends.
enum HotkeyTrigger: Equatable {
    /// Plain Fn — transcript goes into the pill UI.
    case dictate
    /// Fn + Control — transcript gets pasted into the focused text input.
    case insert
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

/// Detects the Fn (globe) key via a CGEvent tap filtered to keycode 63
/// (`kVK_Function`) — the physical Fn key, not the broader "function" mask
/// that fires for arrow keys / F1-F12 / page nav. Also reads whether
/// Control is held at the moment Fn engages so AppDelegate can choose
/// between the pill (Fn alone) and paste-into-input (Fn + Ctrl).
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

    @ObservationIgnored private var eventTap: CFMachPort?
    @ObservationIgnored private var runLoopSource: CFRunLoopSource?
    @ObservationIgnored private var isHeld = false
    @ObservationIgnored private var currentTrigger: HotkeyTrigger = .dictate

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
            // Filter to Fn key specifically (keycode 63) — arrow keys / F-keys
            // also fire flagsChanged with maskSecondaryFn set.
            let keycode = event.getIntegerValueField(.keyboardEventKeycode)
            // swiftlint:disable:next prefer_self_in_static_references
            guard keycode == HotkeyManager.fnKeycode else {
                return Unmanaged.passUnretained(event)
            }
            let flags = event.flags
            let isDown = flags.contains(.maskSecondaryFn)
            let trigger: HotkeyTrigger = flags.contains(.maskControl) ? .insert : .dictate
            let manager = Unmanaged<HotkeyManager>.fromOpaque(info).takeUnretainedValue()
            Task { @MainActor in manager.notify(isDown: isDown, trigger: trigger) }
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

    private func notify(isDown: Bool, trigger: HotkeyTrigger) {
        if isDown, !isHeld {
            // Lock in the trigger mode at the moment Fn engages. The matching
            // Fn-up will see the same mode even if the user releases Ctrl
            // mid-gesture.
            currentTrigger = trigger
            isHeld = true
            onKeyDown?(trigger)
        } else if !isDown, isHeld {
            isHeld = false
            onKeyUp?(currentTrigger)
        }
    }
}
