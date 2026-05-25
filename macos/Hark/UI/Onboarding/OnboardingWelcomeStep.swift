import SwiftUI

/// First step — sets expectations. No system state to probe; the user
/// just reads the bulleted overview and clicks "Get started." Visible
/// only when the user opens onboarding from scratch (firstIncomplete
/// computation lands them here on first run).
struct OnboardingWelcomeStep: View {
    var body: some View {
        VStack(spacing: 18) {
            VStack(alignment: .leading, spacing: 12) {
                bullet(
                    icon: "hand.raised.fill",
                    title: "Three quick permissions",
                    detail: "Microphone, Accessibility, and Input Monitoring."
                )
                bullet(
                    icon: "sparkles",
                    title: "Bring-your-own Claude auth",
                    detail: "Paste an Anthropic API key or use a Claude subscription."
                )
                bullet(
                    icon: "waveform",
                    title: "Try it before you finish",
                    detail: "Record a clip on the last step to verify everything works."
                )
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.background.secondary)
            )

            Text("Hark never bundles credentials. Every step is reversible.")
                .font(.footnote)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private func bullet(icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.system(size: 16, weight: .medium))
                .foregroundStyle(.tint)
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.callout.weight(.medium))
                Text(detail).font(.footnote).foregroundStyle(.secondary)
            }
            Spacer()
        }
    }
}
