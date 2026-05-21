import SwiftUI

struct PanelRootView: View {
    @Bindable var recorder: AudioRecorder

    var body: some View {
        Group {
            switch recorder.state {
            case .idle:
                IdleView()
            case .recording:
                RecordingView(recorder: recorder)
            case .processing:
                ProcessingView()
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(.regularMaterial)
        .animation(.snappy(duration: 0.18), value: recorder.state)
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
            Text("Hold the global hotkey to dictate. The transcript and ticket draft will land here.")
                .font(.callout)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
                .frame(maxWidth: 360)
        }
        .padding(32)
    }
}

private struct ProcessingView: View {
    var body: some View {
        VStack(spacing: 14) {
            ProgressView()
                .controlSize(.large)
            Text("Transcribing…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(32)
    }
}

#Preview("Idle") {
    PanelRootView(recorder: AudioRecorder())
        .frame(width: 560, height: 320)
}
