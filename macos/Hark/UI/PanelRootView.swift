import OSLog
import SwiftUI

private let panelLogger = Logger(subsystem: "co.milbo.hark", category: "Panel")

/// Wispr Flow-style pill UI at the bottom-center of the screen.
/// - Idle: barely-there capsule outline (~40×3); hover hit area matches.
/// - Idle + hover: expands to a compact strip with the three shortcut chips
///   (Fn, ⌃Fn, ⇧Fn) and a settings gear — no text labels, no dividers.
/// - Recording: pulsing red dot + duration + mini bars
/// - Transcribing / loading: spinner + label
/// - Transcript ready: text + copy + dismiss
struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    let actions: PanelActions

    var body: some View {
        VStack {
            Spacer()
            content
                .padding(.bottom, 6)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.clear)
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .recording:
            RecordingPill(recorder: recorder, isCommandMode: false, actions: actions)
                .transition(.scale.combined(with: .opacity))
        case let .processing(label):
            ProcessingPill(label: label, actions: actions)
                .transition(.scale.combined(with: .opacity))
        case let .transcript(text):
            TranscriptPill(text: text, appState: appState)
                .transition(.scale.combined(with: .opacity))
        case let .commandResult(result):
            CommandResultPill(result: result, appState: appState)
                .transition(.scale.combined(with: .opacity))
        case .idle:
            IdlePillView(actions: actions, recorder: recorder)
                .transition(.scale.combined(with: .opacity))
        }
    }

    /// Pure-function derivation lives in PanelViewModel so it's testable.
    /// This view stays thin: observe inputs, render the mode.
    private var mode: PanelViewModel.Mode {
        PanelViewModel.mode(
            recorderState: recorder.state,
            transcriberState: transcriber.state,
            isExecutingCommand: appState.isExecutingCommand,
            isPolishing: appState.isPolishing,
            commandResult: appState.commandResult,
            transcript: appState.transcript
        )
    }
}

// MARK: - Active states

private struct RecordingPill: View {
    @Bindable var recorder: AudioRecorder
    let isCommandMode: Bool
    let actions: PanelActions

    var body: some View {
        // Entire pill is the stop button. The trigger argument is irrelevant
        // here — togglePanelRecording detects the active recording and stops
        // it; nothing new gets started.
        Button {
            actions.toggleRecording(.dictate)
        } label: {
            HStack(spacing: 8) {
                // Stop glyph centered inside the same red dot the user
                // recognizes from recording state. Clarifies the affordance:
                // this control IS clickable, click it to stop.
                ZStack {
                    Circle()
                        .fill(.red)
                        .frame(width: 12, height: 12)
                        .overlay(
                            Circle()
                                .stroke(.red.opacity(0.5), lineWidth: 5)
                                .scaleEffect(1 + CGFloat(min(recorder.level * 5, 1.2)))
                                .opacity(0.7)
                                .animation(.easeOut(duration: 0.12), value: recorder.level)
                        )
                    Image(systemName: "stop.fill")
                        .font(.system(size: 6, weight: .black))
                        .foregroundStyle(.white)
                }

                Text(format(recorder.duration))
                    .font(.system(size: 11, weight: .semibold, design: .rounded))
                    .monospacedDigit()
                    .foregroundStyle(.primary)
                    .contentTransition(.numericText())
                    .animation(.snappy, value: Int(recorder.duration))

                MiniBars(level: recorder.level)
                    .frame(width: 30, height: 12)

                if isCommandMode {
                    ShortcutChip(label: "Command")
                }
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(PillBackground())
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Click to stop")
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ProcessingPill: View {
    let label: String
    let actions: PanelActions

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
            // Escape hatch: any stuck Whisper / polish / execute step can be
            // killed from here without quitting Hark. Without this affordance
            // a hung transcribe would wedge the pill until the timeout fired
            // (or forever, if the timeout itself was wedged).
            Button {
                actions.cancelProcessing()
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 14, height: 14)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Cancel")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PillBackground())
    }
}

private struct CommandResultPill: View {
    let result: AppState.CommandResult
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: result.succeeded ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                .font(.system(size: 12, weight: .medium))
                .foregroundStyle(result.succeeded ? .green : .orange)
            Text(result.summary)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(2)
                .frame(maxWidth: 420, alignment: .leading)
            Button {
                appState.commandResult = nil
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PillBackground())
    }
}

private struct TranscriptPill: View {
    let text: String
    @Bindable var appState: AppState

    var body: some View {
        HStack(spacing: 10) {
            if appState.transcriptInsertFailed {
                Image(systemName: "exclamationmark.bubble.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(.orange)
                    .help("No text input was focused — couldn't paste")
            }
            Text(text)
                .font(.system(size: 11))
                .foregroundStyle(.primary)
                .lineLimit(1)
                .frame(maxWidth: 380, alignment: .leading)

            Button {
                let pb = NSPasteboard.general
                pb.clearContents()
                pb.setString(text, forType: .string)
            } label: {
                Image(systemName: "doc.on.doc")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Copy")

            Button {
                appState.transcript = nil
                appState.transcriptInsertFailed = false
            } label: {
                Image(systemName: "xmark")
                    .font(.system(size: 10, weight: .medium))
            }
            .buttonStyle(.borderless)
            .help("Dismiss")
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PillBackground())
    }
}

// MARK: - Helpers

private struct ShortcutChip: View {
    let label: String

    var body: some View {
        Text(label)
            .font(.system(size: 10, weight: .semibold, design: .rounded))
            .foregroundStyle(.primary)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(.white.opacity(0.14))
            )
    }
}

private struct PillBackground: View {
    var body: some View {
        Capsule(style: .continuous)
            .fill(.black.opacity(0.82))
            .overlay(
                Capsule(style: .continuous)
                    .stroke(.white.opacity(0.1), lineWidth: 0.5)
            )
            .shadow(color: .black.opacity(0.45), radius: 10, y: 3)
    }
}

private struct MiniBars: View {
    let level: Float

    private static let barCount = 5

    var body: some View {
        HStack(alignment: .center, spacing: 2) {
            ForEach(0..<Self.barCount, id: \.self) { index in
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(.red.opacity(0.9))
                    .frame(width: 2.5, height: barHeight(index))
                    .animation(.linear(duration: 0.08), value: level)
            }
        }
    }

    private func barHeight(_ index: Int) -> CGFloat {
        let amplified = CGFloat(min(level * 5, 1))
        let positions: [CGFloat] = [0.3, 0.6, 1.0, 0.7, 0.4]
        return max(2, positions[index] * amplified * 10)
    }
}

#Preview("Idle") {
    PanelRootView(
        appState: AppState(),
        recorder: AudioRecorder(),
        transcriber: Transcriber(),
        actions: PanelActions(toggleRecording: { _ in }, cancelProcessing: {})
    )
    .frame(width: 600, height: 120)
    .background(.gray.opacity(0.2))
}
