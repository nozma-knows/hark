import Foundation
import Observation

/// Drives the step-by-step onboarding wizard. Pure navigation logic on
/// top of an injected status probe — no view code, no
/// ProcessInfo / FileManager / AppKit. Lives in its own type so the
/// "skip already-granted steps" smart-advance behavior can be
/// unit-tested without spinning up a SwiftUI hierarchy or touching real
/// system permissions.
///
/// ### Smart-skip rules
/// On `init`, the model jumps to the first step that isn't already
/// `.complete`. After construction:
/// - `advance()` walks forward, skipping any step whose status is
///   `.complete` or `.skipped`, and stops at the first one that still
///   needs attention. If everything's done, `isFlowComplete` flips true
///   and the caller closes the window.
/// - `back()` walks backward one step at a time. Going back never skips —
///   if the user clicks "Back" we trust them to want that exact step,
///   even if its status is now `.complete`.
/// - `advanceIfCurrentStepCompleted()` is the reactive hook the view
///   calls from `.onChange(of:)` whenever a permission flips. It only
///   advances if the *current* step is the one that just completed —
///   so completing accessibility while we're on microphone doesn't
///   silently jump the user forward.
///
/// ### Why an observable model (not enum-in-View state)
/// The window controller polls `permissions.refresh()` on a 0.5s timer
/// (TCC has no public grant notification). The view needs to react to
/// those refreshes, but the *navigation logic* — which step to skip,
/// when the flow is done — should live somewhere testable.
@MainActor
@Observable
final class OnboardingFlowModel {
    /// Read-only seam the model uses to decide whether a step's
    /// underlying requirement is satisfied. Production wires this to
    /// `PermissionsManager` + `ClaudeAuth`; tests wire it to a mutable
    /// dictionary so navigation logic can be exercised without touching
    /// real system state.
    struct Dependencies {
        /// Return `true` if the step's underlying requirement is met.
        /// Welcome / tryIt should always return `false` here — they're
        /// "needs a click to dismiss" steps, not state-driven ones.
        let isStepRequirementMet: @MainActor (OnboardingStep) -> Bool
    }

    private let deps: Dependencies

    /// Steps the user has explicitly opted to skip. Currently only
    /// `.claudeAuth` is skippable — but the set rather than a bool lets
    /// us add more optional steps without rewriting the navigation logic.
    private var skipped: Set<OnboardingStep> = []

    /// Steps the user has manually marked as already-granted because our
    /// probe disagrees. macOS TCC sometimes shows a permission toggle as
    /// ON in System Settings while still reporting the running process
    /// as untrusted — typically right after a new app version is
    /// installed and the previous build's TCC entry doesn't migrate.
    /// Without an override, the wizard hard-gates Continue on the probe
    /// and traps the user. Treat overridden steps as `.complete` so
    /// navigation behaves the same as a real grant.
    private var userOverrides: Set<OnboardingStep> = []

    /// The step currently visible to the user. Updates trigger SwiftUI
    /// re-renders via `@Observable`.
    private(set) var step: OnboardingStep

    /// `true` once `advance()` has walked past the last step. The view
    /// reads this to dismiss the window.
    private(set) var isFlowComplete: Bool = false

    init(dependencies: Dependencies) {
        deps = dependencies
        step = .welcome
        // After self is fully initialized, jump to the first incomplete
        // step. `firstIncompleteStep()` reads from `self`, so we have to
        // do this after the stored properties are assigned.
        step = firstIncompleteStep() ?? .welcome
    }

    // MARK: - Status

    /// Compute the status of any step from the injected dependencies +
    /// the skipped set. Welcome / tryIt are always `.incomplete` until
    /// the user clicks through (we model "needs a click to dismiss" as
    /// incomplete so the wizard doesn't auto-skip past them).
    func status(of step: OnboardingStep) -> OnboardingStepStatus {
        if userOverrides.contains(step) { return .complete }
        if skipped.contains(step) { return .skipped }
        switch step {
        case .welcome, .tryIt:
            return .incomplete
        case .microphone, .accessibility, .inputMonitoring, .claudeAuth:
            return deps.isStepRequirementMet(step) ? .complete : .incomplete
        }
    }

    /// Can the user click the primary footer button on the current step?
    /// Welcome / tryIt / Claude are always continuable (Claude doubles
    /// as "Skip for now" when auth isn't resolved). Permission steps
    /// gate on actual grant — there's no value in advancing without
    /// microphone, accessibility, or input monitoring.
    var canContinue: Bool {
        switch step {
        case .welcome, .tryIt, .claudeAuth:
            // Claude is always continuable — the button doubles as
            // "Skip for now" when auth isn't resolved. Onboarding
            // without Claude is a supported state.
            true
        case .microphone, .accessibility, .inputMonitoring:
            status(of: step) == .complete
        }
    }

    /// Steps the user has the option to skip (currently Claude auth
    /// only — the OS permissions are non-functional without grants).
    /// Exposed so the view can render a "Skip" affordance conditionally
    /// instead of hard-coding the step ID.
    func canSkip(_ step: OnboardingStep) -> Bool {
        step == .claudeAuth
    }

    // MARK: - Navigation

    /// Move forward to the next step that still needs the user's
    /// attention. Returns true if the step changed; false if there are
    /// no more incomplete steps (and `isFlowComplete` flips true).
    @discardableResult
    func advance() -> Bool {
        guard let currentIndex = OnboardingStep.ordered.firstIndex(of: step) else {
            isFlowComplete = true
            return false
        }
        for candidate in OnboardingStep.ordered.dropFirst(currentIndex + 1) where shouldShow(candidate) {
            step = candidate
            return true
        }
        isFlowComplete = true
        return false
    }

    /// Move backward one step. Unlike `advance()`, this doesn't skip
    /// completed steps — if the user clicks Back they get the step they
    /// see in the progress dots, regardless of current state.
    func back() {
        guard
            let currentIndex = OnboardingStep.ordered.firstIndex(of: step),
            currentIndex > 0 else
        {
            return
        }
        step = OnboardingStep.ordered[currentIndex - 1]
    }

    /// `true` if there's a previous step the user can navigate to.
    var canGoBack: Bool {
        guard let idx = OnboardingStep.ordered.firstIndex(of: step) else { return false }
        return idx > 0
    }

    /// Mark a step as user-skipped (currently `.claudeAuth` only) and
    /// advance past it. No-op if the step isn't skippable.
    func skip(_ target: OnboardingStep) {
        guard canSkip(target) else { return }
        skipped.insert(target)
        if step == target {
            advance()
        }
    }

    /// User claims this permission is already granted — override our
    /// probe and treat the step as complete. Used when the wizard's
    /// `isStepRequirementMet` disagrees with what the user is seeing in
    /// System Settings (post-update TCC drift). Permission steps only;
    /// no-op for welcome / tryIt / claudeAuth, which have their own
    /// navigation paths.
    func acknowledgeGranted(_ target: OnboardingStep) {
        switch target {
        case .microphone, .accessibility, .inputMonitoring:
            userOverrides.insert(target)
            if step == target {
                advance()
            }
        case .welcome, .tryIt, .claudeAuth:
            // Welcome / tryIt aren't gated; claudeAuth uses skip(_:).
            return
        }
    }

    /// Reactive hook: call from the view's `.onChange(of:)` when any
    /// permission flips. Auto-advances ONLY if the current step is the
    /// one that just completed — flipping a later permission while the
    /// user reads the current step shouldn't yank them forward.
    func advanceIfCurrentStepCompleted() {
        guard status(of: step) == .complete else { return }
        advance()
    }

    // MARK: - Internals

    /// The first step that still requires the user's attention. Used by
    /// `init` to land the user on the right step on open, instead of
    /// always starting at welcome and forcing them to click through.
    private func firstIncompleteStep() -> OnboardingStep? {
        OnboardingStep.ordered.first(where: shouldShow)
    }

    /// Should this step be visible during a forward walk? `.complete`
    /// and `.skipped` steps get skipped; everything else is shown.
    private func shouldShow(_ step: OnboardingStep) -> Bool {
        switch status(of: step) {
        case .complete, .skipped:
            false
        case .incomplete:
            true
        }
    }
}

extension OnboardingFlowModel.Dependencies {
    /// Production wiring: read live state from PermissionsManager + ClaudeAuth.
    /// Kept on the type so callers don't reach into the type's internals to
    /// compose a probe closure by hand.
    @MainActor
    static func live(
        permissions: PermissionsManager,
        claudeAuth: ClaudeAuth
    )
        -> Self
    {
        Self(isStepRequirementMet: { step in
            switch step {
            case .welcome, .tryIt:
                false
            case .microphone:
                permissions.microphone == .granted
            case .accessibility:
                permissions.accessibilityTrusted
            case .inputMonitoring:
                permissions.inputMonitoringGranted
            case .claudeAuth:
                claudeAuth.method.isResolved
            }
        })
    }
}
