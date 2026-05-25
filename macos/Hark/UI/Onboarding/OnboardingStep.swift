import Foundation

/// The canonical ordered sequence of steps in the first-run wizard.
///
/// The order matters: each step depends on the previous one being addressed
/// (or skipped). Microphone first because it surfaces the system prompt
/// directly inside the app — no Settings detour. Accessibility + Input
/// Monitoring next because they need a Settings round-trip. Claude auth last
/// because it's the only step we can't probe with a system API.
///
/// `tryIt` is the verification step: the user records a short clip and
/// watches WhisperKit transcribe it inline. Surfacing it last means the
/// success state confirms permissions + transcription + the hot path —
/// not just that the user clicked through.
enum OnboardingStep: String, CaseIterable, Identifiable {
    case welcome
    case microphone
    case accessibility
    case inputMonitoring
    case claudeAuth
    case tryIt

    var id: String { rawValue }

    /// Canonical ordering used by `OnboardingFlowModel` for navigation.
    /// Kept as a static rather than relying on `allCases` because the
    /// model needs a stable index regardless of how Swift compiles `allCases`.
    static let ordered: [Self] = [
        .welcome,
        .microphone,
        .accessibility,
        .inputMonitoring,
        .claudeAuth,
        .tryIt
    ]
}

/// Per-step completion status. Drives both the "skip when navigating
/// forward" behavior in `OnboardingFlowModel` and the visual badge each
/// step view renders.
///
/// - `incomplete`: the step's underlying requirement isn't met yet.
/// - `complete`: granted / configured. Forward navigation skips past these.
/// - `skipped`: optional step the user chose to bypass (Claude auth only —
///   the OS permissions can't be skipped because the app doesn't work
///   without them).
enum OnboardingStepStatus: Equatable {
    case incomplete
    case complete
    case skipped
}
