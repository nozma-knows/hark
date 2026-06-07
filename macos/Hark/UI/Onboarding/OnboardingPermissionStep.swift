import AppKit
import SwiftUI

/// Generic body for any permission step (Microphone / Accessibility /
/// Input Monitoring). All three look the same: a primary action button
/// whose label depends on whether the system has shown the user the
/// prompt yet, plus a help line that adapts to the current grant state.
///
/// Hoisting the shared view eliminates the 3× duplicate
/// PermissionCard / action-mapping code the old onboarding had.
///
/// ### Recovery affordance for post-update TCC drift
/// macOS Catalina+ does not let an app grant itself Accessibility or
/// Input Monitoring — the user has to flip the toggle in System
/// Settings, by hand, every time. After a binary update, macOS
/// sometimes shows the toggle as ON in Settings while still reporting
/// the running process as untrusted (the TCC entry was tied to the
/// previous binary's signature). The honest fix is a process restart:
/// the new launch picks up the current TCC state. We surface
/// "Restart Hark" as the secondary action after the user has tried
/// the normal path once.
struct OnboardingPermissionStep: View {
    /// User-facing copy describing what flips when the user clicks the
    /// primary action — surfaces inline so each step is self-documenting.
    let actionExplanation: String

    /// Live status from `PermissionsManager` for the step's underlying
    /// permission. Drives badge + button label state.
    let status: OnboardingStepStatus

    /// `true` once the user has clicked the primary action at least
    /// once. Used to decide whether to surface the secondary "Restart
    /// Hark to apply" recovery link — no point offering it before the
    /// user has tried the normal path.
    let hasRequested: Bool

    /// Label rendered on the primary action button. Differs by step:
    /// "Allow" for microphone (in-app dialog), "Open System Settings"
    /// for accessibility / input monitoring (where macOS only permits
    /// the toggle to be flipped in Settings). Letting the step view
    /// dictate the label removes the dual-action confusion where we'd
    /// say "Allow" but actually trigger a Settings jump.
    let primaryActionLabel: String

    /// Invoked when the user clicks the primary action.
    let onPrimaryAction: () -> Void

    /// Concrete, numbered actions to take once the user is in System
    /// Settings (e.g. "Find Hark in the list", "Switch the toggle on").
    /// Surfaced only after `hasRequested` flips, so it appears the moment
    /// the user is staring at the Settings pane and wondering what to do —
    /// the exact point we lose people. Empty for the microphone step,
    /// which grants in-app and needs no Settings hunting.
    var settingsSteps: [String] = []

    /// Invoked when the user clicks "Restart Hark to apply" — the
    /// honest fix for post-update TCC drift, where Settings shows the
    /// toggle on but the running process still sees the old (denied)
    /// state. A clean relaunch picks up the new TCC state. Nil for
    /// the microphone step, where drift doesn't happen.
    let onRestartToApply: (() -> Void)?

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
            // Inline "what to do in Settings" guidance. Only after the
            // user has been sent to Settings (hasRequested) and only
            // while the grant is still missing — once granted the step
            // collapses to the green "All set" line.
            if hasRequested, status == .incomplete, !settingsSteps.isEmpty {
                settingsGuidance
            }
            // Recovery affordance for post-update TCC drift. Only show
            // it after the user has tried the normal path once —
            // otherwise it's noise.
            if hasRequested, status == .incomplete, let onRestartToApply {
                Button("Already granted? Restart Hark to apply", action: onRestartToApply)
                    .buttonStyle(.borderless)
                    .font(.footnote)
                    .foregroundStyle(.tint)
            }
        }
    }

    /// Numbered "do this in Settings" checklist. Renders each step in a
    /// row with its ordinal so the user can follow along while the
    /// Settings window is open in front of them.
    private var settingsGuidance: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(Array(settingsSteps.enumerated()), id: \.offset) { index, step in
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text("\(index + 1).")
                        .font(.footnote.weight(.semibold).monospacedDigit())
                        .foregroundStyle(.tint)
                    Text(step)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .frame(maxWidth: 320, alignment: .leading)
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(.background.secondary)
        )
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
                Text(primaryActionLabel)
                    .frame(maxWidth: 220)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
        }
    }
}
