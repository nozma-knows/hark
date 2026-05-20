import Foundation
import KeyboardShortcuts
import Observation

extension KeyboardShortcuts.Name {
    /// The single global hotkey that summons Hark. Defaults to ⌃⌥ Space;
    /// re-bindable by the user via the Hotkey settings pane.
    static let summonPanel = Self(
        "summonPanel",
        default: .init(.space, modifiers: [.control, .option])
    )
}

/// How the global hotkey behaves. Stored as a string in UserDefaults so the
/// raw value is human-readable for debugging via `defaults read`.
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
        case .hold: "Record while the key is held. Best for short bursts."
        case .toggle: "Press once to start, press again to stop. Best for long thoughts."
        }
    }
}

/// Owns the lifecycle of the global hotkey and the user-configurable mode.
/// Exposes raw `onKeyDown` / `onKeyUp` callbacks; semantic interpretation
/// (start recording / stop recording / toggle panel) is the caller's job —
/// see `AppDelegate.requestPanelToggle` in PR 4 and the recording wiring
/// added in PR 5.
@MainActor
@Observable
final class HotkeyManager {
    private static let modeDefaultsKey = "co.milbo.hark.hotkey.mode"

    var mode: HotkeyMode {
        didSet {
            guard mode != oldValue else { return }
            UserDefaults.standard.set(mode.rawValue, forKey: Self.modeDefaultsKey)
        }
    }

    /// Invoked on key press of the configured global shortcut.
    @ObservationIgnored var onKeyDown: (() -> Void)?

    /// Invoked on key release of the configured global shortcut.
    /// Note: requires Accessibility permission (KeyboardShortcuts uses a CGEvent tap).
    @ObservationIgnored var onKeyUp: (() -> Void)?

    init() {
        let stored = UserDefaults.standard.string(forKey: Self.modeDefaultsKey)
        mode = stored.flatMap(HotkeyMode.init(rawValue:)) ?? .hold
        registerHandlers()
    }

    private func registerHandlers() {
        KeyboardShortcuts.onKeyDown(for: .summonPanel) { [weak self] in
            self?.onKeyDown?()
        }
        KeyboardShortcuts.onKeyUp(for: .summonPanel) { [weak self] in
            self?.onKeyUp?()
        }
    }
}
