import OSLog
import SwiftUI

private let panelLogger = Logger(subsystem: "co.milbo.hark", category: "Panel")

/// Wispr Flow-style pill UI at the bottom-center of the screen.
/// - Idle: tiny capsule outline, barely visible (~80×4)
/// - Idle + hover: expands to show the hotkey hint
/// - Recording: pulsing red dot + duration + mini bars
/// - Transcribing / loading: spinner + label
/// - Transcript ready: text + copy + dismiss
struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber

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
        switch derived {
        case .recording:
            RecordingPill(recorder: recorder)
                .transition(.scale.combined(with: .opacity))
        case let .processing(label):
            ProcessingPill(label: label)
                .transition(.scale.combined(with: .opacity))
        case let .transcript(text):
            TranscriptPill(text: text, appState: appState)
                .transition(.scale.combined(with: .opacity))
        case .idle:
            IdlePill()
                .transition(.scale.combined(with: .opacity))
        }
    }

    private enum Derived: Equatable {
        case idle
        case recording
        case processing(label: String)
        case transcript(String)
    }

    private var derived: Derived {
        if recorder.state == .recording { return .recording }
        if case .transcribing = transcriber.state {
            return .processing(label: "Transcribing")
        }
        if appState.isPolishing {
            return .processing(label: "Polishing")
        }
        if case .loading = transcriber.state {
            return .processing(label: "Loading model")
        }
        if case let .downloading(_, progress) = transcriber.state {
            return .processing(label: "Downloading · \(Int(progress * 100))%")
        }
        if let text = appState.transcript, !text.isEmpty {
            return .transcript(text)
        }
        return .idle
    }
}

// MARK: - Idle (smooth morphing pill — outline at rest, full bar on hover)

private struct IdlePill: View {
    @State private var isHovered = false

    private static let collapsedWidth: CGFloat = 72
    private static let collapsedHeight: CGFloat = 5
    private static let expandedWidth: CGFloat = 270
    private static let expandedHeight: CGFloat = 32

    private var pillWidth: CGFloat { isHovered ? Self.expandedWidth : Self.collapsedWidth }
    private var pillHeight: CGFloat { isHovered ? Self.expandedHeight : Self.collapsedHeight }

    var body: some View {
        // Stable outer hit-test area — never resizes, so hover doesn't
        // flicker when the inner pill grows / shrinks past the cursor.
        ZStack {
            Color.clear
                .contentShape(Rectangle())

            ZStack {
                // Background fades in
                Capsule(style: .continuous)
                    .fill(.black.opacity(isHovered ? 0.82 : 0))
                    .overlay(
                        Capsule(style: .continuous)
                            .stroke(.white.opacity(isHovered ? 0.1 : 0), lineWidth: 0.5)
                    )
                    .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 10, y: 3)

                // Outline fades out
                Capsule(style: .continuous)
                    .stroke(.white.opacity(isHovered ? 0 : 0.35), lineWidth: 1)

                HStack(spacing: 8) {
                    ShortcutChip(label: "Fn")
                    Text("dictate")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Divider().frame(height: 12)
                    ShortcutChip(label: "⌃ Fn")
                    Text("paste")
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(.secondary)
                    Spacer(minLength: 4)
                    Image(systemName: "gearshape")
                        .font(.system(size: 14, weight: .medium))
                        .foregroundStyle(.secondary)
                        // Bigger transparent hit target so clicking on the
                        // gear glyph hits cleanly. SwiftUI Buttons inside a
                        // non-activating NSPanel have been unreliable here;
                        // a tap gesture on a sized hit shape works.
                        .frame(width: 22, height: 22)
                        .contentShape(Rectangle())
                        .help("Settings")
                        .onTapGesture {
                            panelLogger.info("Gear tapped — posting openHarkSettings")
                            NotificationCenter.default.post(
                                name: .openHarkSettings,
                                object: nil
                            )
                        }
                }
                .padding(.horizontal, 14)
                .opacity(isHovered ? 1 : 0)
                .allowsHitTesting(isHovered)
            }
            .frame(width: pillWidth, height: pillHeight)
        }
        .frame(width: Self.expandedWidth + 40, height: 48)
        .animation(.easeInOut(duration: 0.28), value: isHovered)
        .onHover { hovering in
            isHovered = hovering
        }
    }
}

// MARK: - Active states

private struct RecordingPill: View {
    @Bindable var recorder: AudioRecorder

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .fill(.red)
                .frame(width: 7, height: 7)
                .overlay(
                    Circle()
                        .stroke(.red.opacity(0.5), lineWidth: 5)
                        .scaleEffect(1 + CGFloat(min(recorder.level * 5, 1.2)))
                        .opacity(0.7)
                        .animation(.easeOut(duration: 0.12), value: recorder.level)
                )

            Text(format(recorder.duration))
                .font(.system(size: 11, weight: .semibold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(.primary)
                .contentTransition(.numericText())
                .animation(.snappy, value: Int(recorder.duration))

            MiniBars(level: recorder.level)
                .frame(width: 30, height: 12)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(PillBackground())
    }

    private func format(_ seconds: TimeInterval) -> String {
        let total = max(Int(seconds), 0)
        return String(format: "%d:%02d", total / 60, total % 60)
    }
}

private struct ProcessingPill: View {
    let label: String

    var body: some View {
        HStack(spacing: 8) {
            ProgressView()
                .controlSize(.small)
                .scaleEffect(0.65)
                .frame(width: 12, height: 12)
            Text(label)
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(.secondary)
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
        transcriber: Transcriber()
    )
    .frame(width: 600, height: 120)
    .background(.gray.opacity(0.2))
}
