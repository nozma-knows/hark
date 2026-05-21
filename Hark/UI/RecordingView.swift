import SwiftUI

/// Live dictation view rendered while `Transcriber.state == .recording`.
/// Text streams in from WhisperKit's AudioStreamTranscriber via the
/// `liveText` observable property; the bottom row visualises the rolling
/// `bufferEnergy` so the user has feedback even before words appear.
struct LiveTranscriptView: View {
    @Bindable var transcriber: Transcriber

    var body: some View {
        VStack(spacing: 0) {
            statusBar
                .padding(.horizontal, 18)
                .padding(.top, 16)
                .padding(.bottom, 10)

            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    if displayText.isEmpty {
                        Text("Listening…")
                            .font(.title3)
                            .foregroundStyle(.tertiary)
                    } else {
                        Text(displayText)
                            .font(.title3)
                            .foregroundStyle(.primary)
                            .textSelection(.disabled)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, 18)
            }
            .defaultScrollAnchor(.bottom)

            EnergyBars(samples: transcriber.bufferEnergy)
                .frame(height: 36)
                .padding(.horizontal, 18)
                .padding(.bottom, 14)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayText: String {
        // Prefer the live text since it's the most recent decode; fall back to
        // confirmed text when the model hasn't emitted partials yet.
        transcriber.liveText.isEmpty ? transcriber.confirmedText : transcriber.liveText
    }

    private var statusBar: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red.gradient)
                .frame(width: 9, height: 9)
            Text("Recording")
                .font(.caption.weight(.medium))
                .foregroundStyle(.secondary)
            Spacer()
            Text("Release to stop")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
    }
}

/// A row of vertical bars whose heights track the rolling `bufferEnergy`
/// signal from `AudioStreamTranscriber`. Renders even when text hasn't
/// arrived yet so the user has feedback the moment they speak.
private struct EnergyBars: View {
    let samples: [Float]

    private static let barCount = 56
    private static let minHeight: CGFloat = 3

    var body: some View {
        GeometryReader { geo in
            let barWidth = max(2, (geo.size.width - CGFloat(Self.barCount - 1) * 3) / CGFloat(Self.barCount))
            HStack(alignment: .center, spacing: 3) {
                ForEach(displayed.indices, id: \.self) { i in
                    Capsule()
                        .fill(Color.accentColor.gradient)
                        .frame(
                            width: barWidth,
                            height: max(Self.minHeight, CGFloat(displayed[i]) * geo.size.height * 4)
                        )
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .animation(.linear(duration: 0.08), value: samples.count)
        }
    }

    /// Take the most recent `barCount` samples, padding from the left if
    /// there's not enough history yet so bars grow into the panel.
    private var displayed: [Float] {
        let take = Array(samples.suffix(Self.barCount))
        let pad = Self.barCount - take.count
        return pad > 0 ? Array(repeating: 0, count: pad) + take : take
    }
}

#Preview {
    LiveTranscriptView(transcriber: Transcriber())
        .frame(width: 560, height: 320)
}
