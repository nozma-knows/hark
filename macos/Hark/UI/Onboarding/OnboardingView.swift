import AppKit
import SwiftUI

struct OnboardingView: View {
    @Bindable var permissions: PermissionsManager
    @Bindable var claudeAuth: ClaudeAuth
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    let onComplete: () -> Void

    var body: some View {
        ScrollView {
            VStack(spacing: 0) {
                header
                    .padding(.top, 28)
                    .padding(.bottom, 18)

                VStack(spacing: 12) {
                    microphoneCard
                    accessibilityCard
                    inputMonitoringCard
                    claudeCard
                }
                .padding(.horizontal, 24)

                // Test-recording step only unlocks once the OS perms +
                // (recommended) Claude auth are squared away. The user
                // has nothing useful to record otherwise.
                if permissions.allGranted {
                    Divider()
                        .padding(.horizontal, 24)
                        .padding(.top, 16)
                    OnboardingTestStep(
                        recorder: recorder,
                        transcriber: transcriber
                    )
                    .padding(.horizontal, 24)
                }

                footer
                    .padding(.horizontal, 24)
                    .padding(.bottom, 24)
                    .padding(.top, 16)
            }
        }
        .frame(width: 480, height: 600)
    }

    private var header: some View {
        VStack(spacing: 8) {
            Image("BrandMark")
                .resizable()
                .renderingMode(.template)
                .aspectRatio(contentMode: .fit)
                .foregroundStyle(.tint)
                .frame(width: 56, height: 56)
            Text("Welcome to Hark")
                .font(.title2.weight(.semibold))
            Text("Two macOS permissions plus Claude auth, then you're set.")
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

    private var inputMonitoringCard: some View {
        PermissionCard(
            systemImage: "keyboard.badge.eye",
            title: "Input Monitoring",
            description: "Required (Catalina+) for the Fn key tap to receive events.",
            status: imCardStatus,
            actionLabel: imCardActionLabel,
            action: imCardAction
        )
    }

    private var claudeCard: some View {
        PermissionCard(
            systemImage: "sparkles",
            title: "Claude auth",
            description: claudeDescription,
            status: claudeCardStatus,
            actionLabel: claudeCardActionLabel,
            action: claudeCardAction
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
            // Continue gates on the two OS permissions only. Claude auth is
            // strongly recommended but skippable — without it the user can
            // still test recording / transcription; they just can't draft
            // tickets until they wire up auth.
            .disabled(!permissions.allGranted)
        }
    }

    // MARK: - Mic card state mapping

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

    // MARK: - Accessibility card state mapping

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

    // MARK: - Input Monitoring card state mapping

    private var imCardStatus: PermissionCard.Status {
        permissions.inputMonitoringGranted ? .granted : .pending
    }

    private var imCardActionLabel: String {
        permissions.inputMonitoringGranted ? "Granted" : "Open Settings"
    }

    private func imCardAction() {
        if !permissions.inputMonitoringGranted {
            permissions.requestInputMonitoring()
            permissions.openInputMonitoringSettings()
        }
    }

    // MARK: - Claude card state mapping

    private var claudeCardStatus: PermissionCard.Status {
        switch claudeAuth.method {
        case .subscription, .apiKey: .granted
        case .none: .pending
        }
    }

    private var claudeDescription: String {
        switch claudeAuth.method {
        case let .subscription(source): "Subscription detected (\(source.rawValue))."
        case let .apiKey(source): "ANTHROPIC_API_KEY detected (\(source.rawValue))."
        case .none where claudeAuth.claudeBinaryPath != nil:
            "Generate an OAuth token with the `claude` CLI."
        case .none:
            "Install Claude Code or set ANTHROPIC_API_KEY."
        }
    }

    private var claudeCardActionLabel: String {
        switch claudeAuth.method {
        case .subscription, .apiKey: "Connected"
        case .none where claudeAuth.claudeBinaryPath != nil: "Generate Token"
        case .none: "Install"
        }
    }

    private func claudeCardAction() {
        switch claudeAuth.method {
        case .subscription, .apiKey:
            break
        case .none:
            if claudeAuth.claudeBinaryPath != nil {
                claudeAuth.runSetupToken()
            } else if let url = URL(string: "https://claude.com/code") {
                NSWorkspace.shared.open(url)
            }
        }
    }
}

#Preview {
    OnboardingView(
        permissions: PermissionsManager(),
        claudeAuth: ClaudeAuth(),
        recorder: AudioRecorder(),
        transcriber: Transcriber(),
        onComplete: {}
    )
}
