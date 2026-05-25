import Foundation
import Observation

/// Observable state shared between `PanelWindowController` (imperative
/// AppKit owner of the NSPanel) and `PanelRootView` (declarative SwiftUI
/// content). The model is the single source of truth for which anchor
/// the pill is parked at and whether the user is currently dragging it.
///
/// - `anchor` drives the SwiftUI alignment so the visible pill renders
///   at the chosen edge of the panel's frame.
/// - `isDragging` lets the pill render a lifted visual state (stronger
///   shadow + slight scale up) without exposing AppKit details to the
///   view layer.
@MainActor
@Observable
final class PillPositionModel {
    var anchor: PillAnchor = PillPositionStore.defaultAnchor
    var isDragging: Bool = false
}
