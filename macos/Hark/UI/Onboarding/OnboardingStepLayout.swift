import SwiftUI

/// Visual variants for the inline "Granted / Skipped / Needs attention"
/// badge next to a step's title. Extracted as a free-standing type so
/// callers can store / pass it without naming the generic step-layout
/// container.
enum OnboardingStepBadge: Equatable {
    case granted
    case skipped
    case attention
}

/// Shared chrome for every onboarding step. Holds the icon, title,
/// description, step-specific body content, and footer bar (Back / Skip /
/// Continue). Centralizing the layout keeps each step view focused on
/// its unique content and ensures the wizard looks identical across
/// all six steps.
///
/// All visual tuning (icon size, padding, footer button styles) lives
/// here. Step views just inject content into the `content` slot.
struct OnboardingStepLayout<Content: View>: View {
    let systemImage: String
    let title: String
    let description: String
    let statusBadge: OnboardingStepBadge?
    let canGoBack: Bool
    let onBack: () -> Void
    let continueLabel: String
    let continueEnabled: Bool
    let onContinue: () -> Void
    let skipLabel: String?
    let onSkip: (() -> Void)?
    @ViewBuilder let content: () -> Content

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 32)
                .padding(.horizontal, 32)

            Spacer(minLength: 16)

            content()
                .frame(maxWidth: .infinity)
                .padding(.horizontal, 32)

            Spacer(minLength: 16)

            footer
                .padding(.horizontal, 24)
                .padding(.vertical, 18)
                .background(.background.tertiary)
        }
    }

    private var header: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage)
                .font(.system(size: 40, weight: .regular))
                .foregroundStyle(.tint)
                .frame(height: 48)

            VStack(spacing: 6) {
                HStack(spacing: 8) {
                    Text(title)
                        .font(.title2.weight(.semibold))
                    if let badge = statusBadge {
                        badgeView(badge)
                    }
                }
                Text(description)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func badgeView(_ kind: OnboardingStepBadge) -> some View {
        Group {
            switch kind {
            case .granted:
                Label("Granted", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .skipped:
                Label("Skipped", systemImage: "minus.circle")
                    .foregroundStyle(.secondary)
            case .attention:
                Label("Needs attention", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }
        }
        .labelStyle(.titleAndIcon)
        .font(.caption.weight(.medium))
        .padding(.horizontal, 8)
        .padding(.vertical, 3)
        .background(Capsule().fill(.background.secondary))
    }

    private var footer: some View {
        HStack {
            Button("Back", action: onBack)
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary)
                .disabled(!canGoBack)
                .opacity(canGoBack ? 1 : 0)

            Spacer()

            if let skipLabel, let onSkip {
                Button(skipLabel, action: onSkip)
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
            }

            Button(continueLabel, action: onContinue)
                .buttonStyle(.borderedProminent)
                .controlSize(.large)
                .keyboardShortcut(.defaultAction)
                .disabled(!continueEnabled)
        }
    }
}
