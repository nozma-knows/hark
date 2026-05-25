import AppKit
import SwiftUI

/// Generic body for any permission step (Microphone / Accessibility /
/// Input Monitoring). All three look the same: a primary action button
/// whose label depends on whether the system has shown the user the
/// prompt yet, plus a help line that adapts to the current grant state.
///
/// Hoisting the shared view eliminates the 3× duplicate
/// PermissionCard / action-mapping code the old onboarding had.
struct OnboardingPermissionStep: View {
    /// User-facing copy describing what flips when the user clicks the
    /// primary action — surfaces inline so each step is self-documenting.
    let actionExplanation: String

    /// Live status from `PermissionsManager` for the step's underlying
    /// permission. Drives badge + button label state.
    let status: OnboardingStepStatus

    /// `true` once the user has clicked the primary action at least
    /// once. After the first click we change the affordance from "Allow"
    /// to "Open Settings" because subsequent clicks won't re-trigger the
    /// system prompt — the user has to flip the toggle in System Settings.
    let hasRequested: Bool

    /// Invoked when the user clicks the primary action. The owning step
    /// view decides whether to call the OS prompt API or jump straight
    /// to System Settings (depending on `hasRequested`).
    let onPrimaryAction: () -> Void

    /// Invoked when the user clicks the "I've already granted this"
    /// override. Used to escape the trap where macOS shows the toggle
    /// as ON in Settings but `AXIsProcessTrusted()` returns false (a
    /// common post-update TCC drift). Nil for the microphone step,
    /// where this drift doesn't happen.
    let onAcknowledgeGranted: (() -> Void)?

    var body: some View {
        VStack(spacing: 16) {
            statusBlock
            primaryActionButton
            Text(actionExplanation)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)
            // Surface the "I've granted it" override only after the
            // user has clicked the primary action at least once — no
            // point offering an escape hatch before they've tried the
            // normal path.
            if hasRequested, status == .incomplete, let onAcknowledgeGranted {
                Button("I've already granted this — continue anyway", action: onAcknowledgeGranted)
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
        }
    }

    @ViewBuilder private var statusBlock: some View {
        switch status {
        case .complete:
            Label("All set — you can move on.", systemImage: "checkmark.circle.fill")
                .foregroundStyle(.green)
                .font(.callout.weight(.medium))
        case .incomplete:
            EmptyView()
        case .skipped:
            EmptyView()
        }
    }

    @ViewBuilder private var primaryActionButton: some View {
        if status == .complete {
            EmptyView()
        } else {
            Button(action: onPrimaryAction) {
                Text(buttonLabel)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }

    private var buttonLabel: String {
        hasRequested ? "Open System Settings" : "Allow"
    }
}
