import Foundation

/// Closures the pill UI calls to drive recording. Keeps `PanelRootView` and
/// its children decoupled from `AppDelegate` — they receive only the actions
/// they need, and AppDelegate owns the actual orchestration (start/stop +
/// finalize-with-trigger).
@MainActor
struct PanelActions {
    /// Toggle recording for the given trigger. If a recording is already in
    /// progress, stops it (regardless of which trigger started it — matches
    /// the user expectation that "click record again" always stops). If not
    /// recording, starts a new recording in the trigger's mode.
    let toggleRecording: (HotkeyTrigger) -> Void
}
