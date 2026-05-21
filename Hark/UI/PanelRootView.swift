import SwiftUI

struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber

    var body: some View {
        Group {
            switch derived {
            case .recording:
                RecordingView(recorder: recorder)
            case .processing:
                ProcessingView(transcriber: transcriber)
            case let .transcript(text):
                TranscriptView(text: text, appState: appState)
            case .idle:
                IdleView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.18), value: derivedKey)
    }

    private enum Derived: Equatable {
        case idle
        case recording
        case processing
        case transcript(String)
    }

    private var derived: Derived {
        if recorder.state == .recording { return .recording }
        if case .transcribing = transcriber.state { return .processing }
        if let text = appState.transcript, !text.isEmpty { return .transcript(text) }
        return .idle
    }

    /// Hashable key used to drive SwiftUI's container transition.
    private var derivedKey: String {
        switch derived {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .transcript: "transcript"
        }
    }
}

private struct IdleView: View {
    var body: some View {
        VStack(spacing: 14) {
            Image(systemName: "waveform")
                .font(.system(size: 36, weight: .light))
                .foregroundStyle(.secondary)
            Text("Hark")
                .font(.title3.weight(.semibold))
            Text("Hold the global hotkey to dictate.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
            HStack(spacing: 6) {
                Text("Press")
                Text("esc")
                    .font(.caption.monospaced())
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(
                        RoundedRectangle(cornerRadius: 4, style: .continuous)
                            .fill(.quaternary)
                    )
                Text("to dismiss")
            }
            .font(.caption)
            .foregroundStyle(.tertiary)
            .padding(.top, 4)
        }
        .padding(32)
    }
}

private struct ProcessingView: View {
    @Bindable var transcriber: Transcriber

    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
                .contentTransition(.opacity)
        }
        .padding(32)
    }

    private var label: String {
        switch transcriber.state {
        case .transcribing: "Transcribing…"
        case .loading: "Loading model…"
        case let .downloading(_, progress): "Downloading model… \(Int(progress * 100))%"
        default: "Processing…"
        }
    }
}

#Preview("Idle") {
    PanelRootView(
        appState: AppState(),
        recorder: AudioRecorder(),
        transcriber: Transcriber()
    )
    .frame(width: 560, height: 320)
}
