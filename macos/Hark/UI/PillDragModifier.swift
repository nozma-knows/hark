import SwiftUI

/// SwiftUI gesture wrapper that turns drag motion on a view into the
/// pill's `beginDrag` / `updateDrag` / `endDrag` action callbacks.
/// Applied to the pill's background capsule (in both `IdlePillView`
/// and the active-state pills), so taps on the pill's buttons aren't
/// intercepted — buttons live above the background in the ZStack and
/// claim taps under the drag's `minimumDistance` threshold.
///
/// Drag eligibility is gated by `isEnabled`. While the pill is in any
/// non-idle state (recording / transcribing / showing transcript) the
/// modifier no-ops — preventing accidental flings while the user is
/// reaching for the stop or copy buttons.
struct PillDragModifier: ViewModifier {
    let isEnabled: Bool
    let actions: PanelActions

    /// SwiftUI's `DragGesture` fires `onChanged` repeatedly without a
    /// distinct "start" callback, so the modifier tracks whether it has
    /// notified the actions yet for this gesture instance. Flipped on
    /// the first non-zero translation, cleared on `onEnded`.
    @State private var didBegin = false

    /// Minimum drag distance before a gesture is treated as a drag (vs.
    /// a swallowed tap). 4pt is small enough that intentional drags feel
    /// immediate, large enough that incidental cursor wiggle on a
    /// click-through region doesn't start a pill move.
    static let minimumDragDistance: CGFloat = 4

    func body(content: Content) -> some View {
        guard isEnabled else { return AnyView(content) }
        let gesture = DragGesture(
            minimumDistance: Self.minimumDragDistance,
            coordinateSpace: .global
        )
        .onChanged { value in
            if !didBegin {
                didBegin = true
                actions.beginDrag()
            }
            actions.updateDrag(value.translation)
        }
        .onEnded { value in
            actions.endDrag(value.translation)
            didBegin = false
        }
        return AnyView(content.gesture(gesture))
    }
}

extension View {
    /// Convenience that reads more naturally at the call site than
    /// `.modifier(PillDragModifier(...))`.
    func pillDraggable(_ enabled: Bool, actions: PanelActions) -> some View {
        modifier(PillDragModifier(isEnabled: enabled, actions: actions))
    }
}
