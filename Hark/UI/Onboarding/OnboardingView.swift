import SwiftUI

struct OnboardingView: View {
    @Bindable var permissions: PermissionsManager
    let onComplete: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
                .padding(.top, 28)
                .padding(.bottom, 18)

            VStack(spacing: 12) {
                microphoneCard
                accessibilityCard
            }
            .padding(.horizontal, 24)

            Spacer(minLength: 24)

            footer
                .padding(.horizontal, 24)
                .padding(.bottom, 24)
        }
        .frame(width: 480, height: 520)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image(systemName: "waveform")
                .font(.system(size: 44, weight: .light))
                .foregroundStyle(.tint)
            Text("Welcome to Hark")
                .font(.title2.weight(.semibold))
            Text("Two macOS permissions, then you're ready to dictate.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
    }

    private var microphoneCard: some View {
        PermissionCard(
            systemImage: "mic.fill",
            title: "Microphone",
            description: "Capture your voice locally to transcribe.",
            status: micCardStatus,
            actionLabel: micCardActionLabel,
            action: micCardAction
        )
    }

    private var accessibilityCard: some View {
        PermissionCard(
            systemImage: "keyboard",
            title: "Accessibility",
            description: "Watch for the global hotkey when Hark isn't focused.",
            status: axCardStatus,
            actionLabel: axCardActionLabel,
            action: axCardAction
        )
    }

    private var footer: some View {
        HStack {
            Button("Quit Hark") {
                NSApplication.shared.terminate(nil)
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)

            Spacer()

            Button("Continue") {
                onComplete()
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.large)
            .keyboardShortcut(.defaultAction)
            .disabled(!permissions.allGranted)
        }
    }

    // MARK: - Card state mapping

    private var micCardStatus: PermissionCard.Status {
        switch permissions.microphone {
        case .granted: .granted
        case .denied: .denied
        case .undetermined: .pending
        }
    }

    private var micCardActionLabel: String {
        switch permissions.microphone {
        case .granted: "Granted"
        case .denied: "Open Settings"
        case .undetermined: "Grant"
        }
    }

    private func micCardAction() {
        switch permissions.microphone {
        case .undetermined:
            Task { await permissions.requestMicrophone() }
        case .denied:
            permissions.openMicrophoneSettings()
        case .granted:
            break
        }
    }

    private var axCardStatus: PermissionCard.Status {
        permissions.accessibilityTrusted ? .granted : .pending
    }

    private var axCardActionLabel: String {
        permissions.accessibilityTrusted ? "Granted" : "Open Settings"
    }

    private func axCardAction() {
        if !permissions.accessibilityTrusted {
            permissions.promptAccessibility()
            permissions.openAccessibilitySettings()
        }
    }
}

#Preview {
    OnboardingView(permissions: PermissionsManager(), onComplete: {})
}
