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
}
