import AppKit
import SwiftUI

/// Step-by-step first-run wizard. One step at a time, smart enough to
/// skip permissions that are already granted on open and to auto-advance
/// the moment the user flips a toggle in System Settings.
///
/// All navigation lives in `OnboardingFlowModel`; this view is just the
/// renderer + the per-step content. State that's strictly UI-local
/// (whether the user has clicked "Allow" once already) stays in
/// `@State` here — the flow model only cares about objective system
/// state.
struct OnboardingView: View {
    @Bindable var permissions: PermissionsManager
    @Bindable var claudeAuth: ClaudeAuth
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    let onComplete: () -> Void

    @State private var model: OnboardingFlowModel
    /// Tracks per-permission "have we shown the system prompt yet."
    /// Microphone status uses `.undetermined` for this; accessibility +
    /// input monitoring don't expose that state, so we track locally.
    /// Reset implicitly each time the window opens (this is `@State`).
    @State private var accessibilityRequested = false
    @State private var inputMonitoringRequested = false

    init(
        permissions: PermissionsManager,
        claudeAuth: ClaudeAuth,
        recorder: AudioRecorder,
        transcriber: Transcriber,
        onComplete: @escaping () -> Void
    ) {
        self.permissions = permissions
        self.claudeAuth = claudeAuth
        self.recorder = recorder
        self.transcriber = transcriber
        self.onComplete = onComplete
        _model = State(initialValue: OnboardingFlowModel(
            dependencies: .live(permissions: permissions, claudeAuth: claudeAuth)
        ))
    }

    var body: some View {
        VStack(spacing: 0) {
            OnboardingProgressDots(
                steps: OnboardingStep.ordered,
                current: model.step,
                statusOf: model.status(of:)
            )
            .padding(.top, 8)

            Divider().opacity(0.5)

            currentStepView
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity.combined(with: .move(edge: .trailing)))
                .id(model.step)
                .animation(.easeInOut(duration: 0.16), value: model.step)
        }
        .frame(width: 520, height: 520)
        .onChange(of: permissions.microphone) { _, _ in model.advanceIfCurrentStepCompleted() }
        .onChange(of: permissions.accessibilityTrusted) { _, _ in model.advanceIfCurrentStepCompleted() }
        .onChange(of: permissions.inputMonitoringGranted) { _, _ in model.advanceIfCurrentStepCompleted() }
        .onChange(of: claudeAuth.method) { _, _ in model.advanceIfCurrentStepCompleted() }
        .onChange(of: model.isFlowComplete) { _, complete in
            if complete { onComplete() }
        }
    }

    // MARK: - Step rendering

    @ViewBuilder private var currentStepView: some View {
        switch model.step {
        case .welcome:
            welcomeStep
        case .microphone:
            microphoneStep
        case .accessibility:
            accessibilityStep
        case .inputMonitoring:
            inputMonitoringStep
        case .claudeAuth:
            claudeStep
        case .tryIt:
            tryItStep
        }
    }

    private var welcomeStep: some View {
        OnboardingStepLayout(
            systemImage: "waveform.circle.fill",
            title: "Welcome to Hark",
            description: "Hold Fn, speak, release. Hark transcribes locally and polishes with Claude.",
            statusBadge: nil,
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: "Get started",
            continueEnabled: true,
            onContinue: { model.advance() },
            skipLabel: nil,
            onSkip: nil
        ) {
            OnboardingWelcomeStep()
        }
    }

    private var microphoneStep: some View {
        let status = model.status(of: .microphone)
        return OnboardingStepLayout(
            systemImage: "mic.fill",
            title: "Microphone",
            description: "Hark records your audio on-device so WhisperKit can transcribe it.",
            statusBadge: status == .complete ? .granted : nil,
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: "Continue",
            continueEnabled: model.canContinue,
            onContinue: { model.advance() },
            skipLabel: nil,
            onSkip: nil
        ) {
            OnboardingPermissionStep(
                actionExplanation: micExplanation,
                status: status,
                hasRequested: permissions.microphone != .undetermined,
                onPrimaryAction: handleMicrophoneAction
            )
        }
    }

    private var accessibilityStep: some View {
        let status = model.status(of: .accessibility)
        return OnboardingStepLayout(
            systemImage: "keyboard",
            title: "Accessibility",
            description: "Required so Hark can watch for the Fn (🌐) key even when another app is focused.",
            statusBadge: status == .complete ? .granted : nil,
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: "Continue",
            continueEnabled: model.canContinue,
            onContinue: { model.advance() },
            skipLabel: nil,
            onSkip: nil
        ) {
            OnboardingPermissionStep(
                actionExplanation:
                "After clicking, toggle Hark on under Privacy & Security → Accessibility. "
                    + "The wizard advances automatically.",
                status: status,
                hasRequested: accessibilityRequested,
                onPrimaryAction: handleAccessibilityAction
            )
        }
    }

    private var inputMonitoringStep: some View {
        let status = model.status(of: .inputMonitoring)
        return OnboardingStepLayout(
            systemImage: "keyboard.badge.eye",
            title: "Input Monitoring",
            description: "Catalina+ requires this for keyboard event taps to actually receive events.",
            statusBadge: status == .complete ? .granted : nil,
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: "Continue",
            continueEnabled: model.canContinue,
            onContinue: { model.advance() },
            skipLabel: nil,
            onSkip: nil
        ) {
            OnboardingPermissionStep(
                actionExplanation:
                "Toggle Hark on under Privacy & Security → Input Monitoring. "
                    + "Without this, Hark would silently miss every Fn keypress.",
                status: status,
                hasRequested: inputMonitoringRequested,
                onPrimaryAction: handleInputMonitoringAction
            )
        }
    }

    private var claudeStep: some View {
        let status = model.status(of: .claudeAuth)
        return OnboardingStepLayout(
            systemImage: "sparkles",
            title: "Connect Claude",
            description: "Hark needs Claude credentials to polish transcripts and run voice commands.",
            statusBadge: claudeBadge(for: status),
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: status == .incomplete ? "Skip for now" : "Continue",
            continueEnabled: true,
            onContinue: claudeContinue,
            skipLabel: nil,
            onSkip: nil
        ) {
            OnboardingClaudeStep(claudeAuth: claudeAuth)
        }
    }

    private var tryItStep: some View {
        OnboardingStepLayout(
            systemImage: "waveform.badge.checkmark",
            title: "Try it now",
            description: "Record a short clip and watch WhisperKit transcribe it inline.",
            statusBadge: nil,
            canGoBack: model.canGoBack,
            onBack: { model.back() },
            continueLabel: "Done",
            continueEnabled: true,
            onContinue: { onComplete() },
            skipLabel: "Skip",
            onSkip: { onComplete() }
        ) {
            OnboardingTestStep(recorder: recorder, transcriber: transcriber)
        }
    }

    // MARK: - Step actions

    private var micExplanation: String {
        switch permissions.microphone {
        case .granted:
            "Microphone access is granted."
        case .undetermined:
            "macOS will ask once. You can change this any time in System Settings."
        case .denied:
            "Hark needs microphone access to record audio. Re-enable it under Privacy & Security → Microphone."
        }
    }

    private func handleMicrophoneAction() {
        switch permissions.microphone {
        case .undetermined:
            Task { await permissions.requestMicrophone() }
        case .denied:
            permissions.openMicrophoneSettings()
        case .granted:
            break
        }
    }

    private func handleAccessibilityAction() {
        permissions.promptAccessibility()
        permissions.openAccessibilitySettings()
        accessibilityRequested = true
    }

    private func handleInputMonitoringAction() {
        permissions.requestInputMonitoring()
        permissions.openInputMonitoringSettings()
        inputMonitoringRequested = true
    }

    private func claudeBadge(for status: OnboardingStepStatus) -> OnboardingStepBadge? {
        switch status {
        case .complete: .granted
        case .skipped: .skipped
        case .incomplete: nil
        }
    }

    private func claudeContinue() {
        if model.status(of: .claudeAuth) == .incomplete {
            model.skip(.claudeAuth)
        } else {
            model.advance()
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
