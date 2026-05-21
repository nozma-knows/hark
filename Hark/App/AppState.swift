import Foundation
import Observation

/// The single source of truth for app-wide observable UI state. Lives on the
/// main actor; everything in Hark that mutates UI flows through here so we can
/// keep imperative AppKit (NSPanel, NSStatusItem) and declarative SwiftUI views
/// in sync without duplicate ownership.
@MainActor
@Observable
final class AppState {
    /// Whether the floating panel should be visible. Toggling this is the only
    /// supported way to show or hide the panel — `PanelWindowController`
    /// observes the value and drives the underlying `NSPanel`.
    var isPanelVisible: Bool = false

    /// The most recent transcription, if any. Cleared when a new recording
    /// starts. The panel renders the transcript when this is non-nil and the
    /// recorder/transcriber are idle.
    var transcript: String?

    /// Whether the most recent transcription was attempted as a paste-into-
    /// input (Fn + Ctrl) but no focused text input was found. The pill shows
    /// a "no input focused" hint when this is true.
    var transcriptInsertFailed = false
}
