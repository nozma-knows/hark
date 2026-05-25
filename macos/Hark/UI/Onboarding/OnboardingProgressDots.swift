import SwiftUI

/// Slim progress strip rendered at the top of the wizard. One dot per
/// step in the canonical order; the active step is wider and tinted,
/// completed steps fill solid, future steps render hollow.
///
/// Tap targets are intentionally inert — dots are visual progress only.
/// Skipping forward without satisfying a step would defeat the wizard's
/// purpose; the user navigates with Back / Continue.
struct OnboardingProgressDots: View {
    let steps: [OnboardingStep]
    let current: OnboardingStep
    /// Closure returning a step's current completion state. Injected so
    /// the dot strip can render granted steps differently from pending
    /// ones without holding a reference to the flow model.
    let statusOf: (OnboardingStep) -> OnboardingStepStatus

    var body: some View {
        HStack(spacing: 6) {
            ForEach(steps) { step in
                Capsule()
                    .fill(color(for: step))
                    .frame(width: step == current ? 18 : 6, height: 6)
                    .animation(.easeInOut(duration: 0.18), value: current)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func color(for step: OnboardingStep) -> Color {
        if step == current {
            return .accentColor
        }
        switch statusOf(step) {
        case .complete:
            return .green.opacity(0.7)
        case .skipped:
            return .secondary.opacity(0.4)
        case .incomplete:
            return .secondary.opacity(0.25)
        }
    }
}
