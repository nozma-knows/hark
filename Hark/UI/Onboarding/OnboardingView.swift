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

            if permissions.accessibilityTrusted {
                relaunchBanner
                    .padding(.horizontal, 24)
                    .padding(.top, 14)
            }

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

    /// macOS caches an app's Accessibility trust at process-start time for the
    /// CGEventTap that KeyboardShortcuts installs — granting mid-run leaves
    /// trust true but the tap dead until next launch.
    private var relaunchBanner: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.clockwise.circle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("Relaunch Hark for the global hotkey to start working.")
                    .font(.callout.weight(.medium))
                Text("Accessibility trust is cached at launch.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Relaunch") {
                relaunch()
            }
            .buttonStyle(.bordered)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.orange.opacity(0.08))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(.orange.opacity(0.4), lineWidth: 0.5)
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

            Button("Check again") {
                permissions.refresh()
            }
            .buttonStyle(.bordered)

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

    private func relaunch() {
        guard let bundleURL = Bundle.main.bundleURL as URL? else { return }
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: bundleURL, configuration: config) { _, _ in
            Task { @MainActor in
                NSApplication.shared.terminate(nil)
            }
        }
    }
}

#Preview {
    OnboardingView(permissions: PermissionsManager(), onComplete: {})
}
