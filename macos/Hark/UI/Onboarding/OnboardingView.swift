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
            if complete { finish() }
        }
    }

    /// Single exit point for the wizard. Records that the user reached
    /// the end (so post-onboarding nudges can fire) and hands control
    /// back to the window controller to close.
    private func finish() {
        OnboardingProgress.markCompleted()
        onComplete()
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
                primaryActionLabel: micButtonLabel,
                onPrimaryAction: handleMicrophoneAction,
                // Mic detection goes through AVFoundation — granted/denied/
                // undetermined is unambiguous. No "restart to apply"
                // escape hatch needed here.
                onRestartToApply: nil
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
                "macOS only allows this toggle to be flipped in System Settings — apps can't grant "
                    + "themselves Accessibility. The wizard advances automatically once you toggle Hark on.",
                status: status,
                hasRequested: model.hasRequested(.accessibility),
                primaryActionLabel: "Open System Settings",
                onPrimaryAction: handleAccessibilityAction,
                settingsSteps: Self.accessibilityGuidance,
                onRestartToApply: { AppRelauncher.relaunch() }
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
                "macOS only allows this toggle to be flipped in System Settings — apps can't grant "
                    + "themselves Input Monitoring. Toggle Hark on and the wizard advances automatically.",
                status: status,
                hasRequested: model.hasRequested(.inputMonitoring),
                primaryActionLabel: "Open System Settings",
                onPrimaryAction: handleInputMonitoringAction,
                settingsSteps: Self.inputMonitoringGuidance,
                onRestartToApply: { AppRelauncher.relaunch() }
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
            onContinue: { finish() },
            skipLabel: "Skip",
            onSkip: { finish() }
        ) {
            OnboardingTestStep(recorder: recorder, transcriber: transcriber)
        }
    }

    // MARK: - Settings guidance

    /// Concrete step-by-step shown once the user has been sent to the
    /// Accessibility pane. The System Settings round-trip is the single
    /// biggest onboarding drop-off point — users land in a long list and
    /// don't know what to do. Spelling out "Hark is already here, flip
    /// the switch" removes the guesswork. Kept as plain text (no bundled
    /// screenshot) so it stays correct as macOS reshuffles the pane.
    private static let accessibilityGuidance = [
        "Find Hark in the list on the right (it's already there).",
        "Switch the toggle next to Hark on.",
        "Come back here — the wizard moves on automatically."
    ]

    private static let inputMonitoringGuidance = [
        "Find Hark in the Input Monitoring list (it's already there).",
        "Switch the toggle next to Hark on.",
        "Come back here — the wizard moves on automatically."
    ]

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

    /// Button label for the microphone step. Unlike AX/IM, the mic
    /// permission has a true in-app grant flow on first use — the
    /// label reflects which action will actually happen.
    private var micButtonLabel: String {
        switch permissions.microphone {
        case .undetermined: "Allow"
        case .denied: "Open System Settings"
        case .granted: "Allow"
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
        // No system dialog. On macOS 14+ calling AXIsProcessTrustedWithOptions
        // can EITHER show a "Open System Settings / Deny" dialog OR
        // auto-open Settings outright (varies by minor version) — when
        // both happen the user sees a dialog asking them to do something
        // we already did, which reads as the app deciding for them.
        // Skip the dialog entirely and just take them to the right
        // Settings pane. HotkeyManager already called AXIsProcessTrusted
        // at launch, which is what registers Hark in the Accessibility
        // list, so the toggle is already there waiting.
        permissions.openAccessibilitySettings()
        model.markRequested(.accessibility)
    }

    private func handleInputMonitoringAction() {
        // Same reasoning as accessibility: IOHIDRequestAccess on
        // Sonoma/Tahoe shows a notification AND can auto-open Settings,
        // producing a confusing two-action experience. HotkeyManager
        // already called IOHIDCheckAccess at launch (which registers
        // Hark in the Input Monitoring list); we just need to take the
        // user to the pane so they can toggle.
        permissions.openInputMonitoringSettings()
        model.markRequested(.inputMonitoring)
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
