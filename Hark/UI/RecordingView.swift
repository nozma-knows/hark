import SwiftUI

struct RecordingView: View {
    @Bindable var recorder: AudioRecorder

    var body: some View {
        VStack(spacing: 22) {
            indicator
            timer
            LevelMeter(level: recorder.level)
                .frame(width: 220)
            Text("Release to stop")
                .font(.callout)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(32)
    }

    private var indicator: some View {
        Circle()
            .fill(.red.gradient)
            .frame(width: 14, height: 14)
            .overlay(
                Circle()
                    .stroke(.red.opacity(0.35), lineWidth: 6)
                    .scaleEffect(1.0 + CGFloat(min(recorder.level * 6, 1.4)))
                    .opacity(0.6)
                    .animation(.easeOut(duration: 0.12), value: recorder.level)
            )
    }

    private var timer: some View {
        Text(Self.format(recorder.duration))
            .font(.system(size: 36, weight: .medium, design: .rounded))
            .monospacedDigit()
            .contentTransition(.numericText())
            .animation(.snappy, value: Int(recorder.duration))
    }

    private static func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

struct LevelMeter: View {
    let level: Float

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule()
                    .fill(.quaternary)
                Capsule()
                    .fill(Color.accentColor.gradient)
                    .frame(width: geo.size.width * scaled)
                    .animation(.easeOut(duration: 0.08), value: level)
            }
        }
        .frame(height: 6)
    }

    /// RMS sits in [0, ~0.3] for typical dictation; scale up so the bar is
    /// readable without clipping at louder peaks.
    private var scaled: CGFloat {
        let amplified = min(max(level * 3, 0), 1)
        return CGFloat(amplified)
    }
}

#Preview("Recording") {
    let recorder = AudioRecorder()
    return RecordingView(recorder: recorder)
        .frame(width: 560, height: 320)
}
