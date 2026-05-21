import SwiftUI

struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var transcriber: Transcriber

    var body: some View {
        Group {
            switch derived {
            case .recording:
                LiveTranscriptView(transcriber: transcriber)
            case let .processing(label, progress):
                ProcessingView(label: label, progress: progress)
            case let .transcript(text):
                TranscriptView(text: text, appState: appState)
            case let .failed(message):
                FailureView(message: message)
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
        case processing(label: String, progress: Double?)
        case transcript(String)
        case failed(String)
    }

    private var derived: Derived {
        switch transcriber.state {
        case .recording:
            return .recording
        case let .downloading(model, progress):
            return .processing(label: "Downloading \(model.shortName) model…", progress: progress)
        case let .loading(model):
            return .processing(label: "Loading \(model.shortName) model…", progress: nil)
        case let .failed(message):
            return .failed(message)
        case .unloaded, .ready:
            break
        }
        if let text = appState.transcript, !text.isEmpty {
            return .transcript(text)
        }
        return .idle
    }

    private var derivedKey: String {
        switch derived {
        case .idle: "idle"
        case .recording: "recording"
        case .processing: "processing"
        case .transcript: "transcript"
        case .failed: "failed"
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
    let label: String
    let progress: Double?

    var body: some View {
        VStack(spacing: 14) {
            if let progress {
                ProgressView(value: progress)
                    .progressViewStyle(.linear)
                    .frame(maxWidth: 280)
                Text("\(label)  \(Int(progress * 100))%")
                    .font(.callout)
                    .foregroundStyle(.secondary)
            } else {
                ProgressView()
                    .controlSize(.large)
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(32)
    }
}

private struct FailureView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.system(size: 30))
            Text("Transcription failed")
                .font(.headline)
            Text(message)
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 380)
        }
        .padding(28)
    }
}

#Preview("Idle") {
    PanelRootView(appState: AppState(), transcriber: Transcriber())
        .frame(width: 560, height: 320)
}
