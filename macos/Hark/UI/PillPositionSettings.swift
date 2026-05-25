import Foundation

/// Small, focused interface the Settings UI uses to drive the pill's
/// position controls. Keeps `GeneralPane` decoupled from
/// `PanelWindowController` — the pane reads the current anchor
/// reactively via the `@Bindable` model, and triggers resets through
/// the two closures.
@MainActor
struct PillPositionSettings {
    /// Observable model — drives the "Current position" label as the
    /// user drags or resets the pill.
    let model: PillPositionModel
    /// True iff at least one display has a stored anchor. Hides the
    /// "Reset all displays" affordance until it would do something.
    let hasAnyStoredAnchor: () -> Bool
    /// Reset the pill anchor on the active screen to the default
    /// (`.center`) and reposition the pill.
    let resetActive: () -> Void
    /// Wipe every stored display anchor and reposition the pill on the
    /// active screen using the default.
    let resetAll: () -> Void
}
