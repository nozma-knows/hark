import Foundation

/// Closures the pill UI calls to drive recording + reposition. Keeps
/// `PanelRootView` and its children decoupled from `AppDelegate` and
/// `PanelWindowController` — they receive only the actions they need,
/// and the owning controllers handle the actual side effects.
@MainActor
struct PanelActions {
    /// Toggle recording for the given trigger. If a recording is already in
    /// progress, stops it (regardless of which trigger started it — matches
    /// the user expectation that "click record again" always stops). If not
    /// recording, starts a new recording in the trigger's mode.
    let toggleRecording: (HotkeyTrigger) -> Void
    /// Force-abort whatever post-recording step is currently running
    /// (transcribe / polish / executeCommand). Resets the pill to idle so
    /// the user can recover from a hung Whisper or Claude call.
    let cancelProcessing: () -> Void
    /// User started a drag on the pill. Captures the panel's current
    /// origin so subsequent `updateDrag` translations can be applied
    /// from a stable reference. Idempotent — calling twice in a row
    /// without `endDrag` in between is a no-op.
    let beginDrag: () -> Void
    /// Translation from the drag-start origin. The pill moves live to
    /// `start + translation`, clamped to the visible frame and pulled
    /// toward nearest anchor while within snap distance.
    let updateDrag: (CGSize) -> Void
    /// Final translation. The pill snaps to the nearest anchor, the
    /// anchor is persisted for the current screen, and `beginDrag`'s
    /// captured origin is cleared.
    let endDrag: (CGSize) -> Void
}
