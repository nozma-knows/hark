import AppKit
import SwiftUI

/// "Try it now" step at the end of onboarding. The user records a
/// short clip, Hark transcribes it locally, and the result appears
/// inline — proves end-to-end that mic + WhisperKit + the hotkey
/// pipeline are all working before the user has to actually try a
/// real dictation.
///
/// Owns its own recorder/transcribe lifecycle through the same
/// dependencies the orchestrator uses. The onboarding controller
/// passes them in instead of standing up a parallel pipeline.
struct OnboardingTestStep: View {
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber

    @State private var phase: Phase = .idle
    @State private var transcribed: String?
    @State private var errorMessage: String?

    enum Phase: Equatable {
        case idle
        case recording
        case transcribing
        case done
        case failed
    }

    /// Compact body used inside the onboarding wizard. The wrapping
    /// `OnboardingStepLayout` already provides the icon, title, and
    /// outer padding, so this view focuses purely on the recording
    /// affordance and result block.
    var body: some View {
        VStack(spacing: 14) {
            Text(instruction)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 8)

            recordButton

            resultBlock
                .frame(minHeight: 60, alignment: .top)
        }
        .frame(maxWidth: .infinity)
    }

    // MARK: - Subviews

    @ViewBuilder private var recordButton: some View {
        switch phase {
        case .idle, .failed:
            Button {
                start()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "mic.fill")
                    Text(phase == .failed ? "Try again" : "Start recording")
                        .font(.headline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
        case .recording:
            Button {
                stop()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "stop.fill")
                    Text("Stop")
                        .font(.headline)
                }
                .padding(.horizontal, 24)
                .padding(.vertical, 10)
            }
            .buttonStyle(.borderedProminent)
            .tint(.red)
        case .transcribing:
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Transcribing…")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        case .done:
            Button {
                reset()
            } label: {
                Label("Record another", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder private var resultBlock: some View {
        switch phase {
        case .done:
            VStack(alignment: .leading, spacing: 6) {
                Label("Got it", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
                    .font(.callout.weight(.medium))
                Text(transcribed ?? "")
                    .font(.system(size: 13))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(10)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(.tint.opacity(0.08))
                    )
            }
            .padding(.horizontal, 24)
        case .failed:
            Label(errorMessage ?? "Something didn't work", systemImage: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.callout)
                .padding(.horizontal, 24)
        default:
            EmptyView()
        }
    }

    // MARK: - Phase transitions

    private var instruction: String {
        switch phase {
        case .idle: "Click below, say a sentence or two, and we'll transcribe it right here."
        case .recording: "Recording… click stop when you're done."
        case .transcribing: "Running WhisperKit on the audio you just spoke."
        case .done: "Permissions, mic, and on-device transcription all work."
        case .failed: "We can debug this — try once more, then check the General → Log file if it persists."
        }
    }

    private func start() {
        transcribed = nil
        errorMessage = nil
        do {
            try recorder.start()
            phase = .recording
        } catch {
            errorMessage = (error as? LocalizedError)?.errorDescription ?? "Couldn't access the microphone."
            phase = .failed
        }
    }

    private func stop() {
        let samples = recorder.stop()
        guard !samples.isEmpty else {
            errorMessage = "No audio captured. Make sure the mic is connected and not muted."
            phase = .failed
            return
        }
        phase = .transcribing
        Task {
            do {
                let text = try await transcriber.transcribe(samples: samples)
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.isEmpty {
                    errorMessage = "Whisper didn't recognize any speech. Try again, a little louder."
                    phase = .failed
                } else {
                    transcribed = trimmed
                    phase = .done
                }
            } catch {
                errorMessage = (error as? LocalizedError)?.errorDescription
                    ?? "Transcription failed: \(error.localizedDescription)"
                phase = .failed
            }
        }
    }

    private func reset() {
        transcribed = nil
        errorMessage = nil
        phase = .idle
    }
}
