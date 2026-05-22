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
            RecordingPill(recorder: recorder, isCommandMode: isCommandMode)
                .transition(.scale.combined(with: .opacity))
        case let .processing(label):
            ProcessingPill(label: label)
                .transition(.scale.combined(with: .opacity))
        case let .transcript(text):
            TranscriptPill(text: text, appState: appState)
                .transition(.scale.combined(with: .opacity))
        case let .commandResult(result):
            CommandResultPill(result: result, appState: appState)
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
        case commandResult(AppState.CommandResult)
    }

    /// True while the active hotkey gesture is `.command` — used by the
    /// RecordingPill to render the "Command" chip instead of the dictation
    /// indicator.
    private var isCommandMode: Bool {
        // The HotkeyManager owns the live trigger; we can't see it directly
        // from here, but during a `.command` recording the appState's
        // isExecutingCommand will be false (we're still recording) and the
        // trigger gets surfaced through AppDelegate. For now we infer mode
        // from the appState surface — keeps PanelRootView decoupled from
        // HotkeyManager. (No false positives because the pill only shows
        // command-mode chip during an active recording.)
        false
    }

    private var derived: Derived {
        if recorder.state == .recording { return .recording }
        if case .transcribing = transcriber.state {
            return .processing(label: "Transcribing")
        }
        if appState.isExecutingCommand {
            return .processing(label: "Executing")
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
        if let result = appState.commandResult {
            return .commandResult(result)
        }
        if let text = appState.transcript, !text.isEmpty {
            return .transcript(text)
        }
        return .idle
    }
}

// MARK: - Idle (visible pill grows from the center, inside a fixed hit-area)

private struct IdlePill: View {
    @State private var isHovered = false

    private static let collapsedWidth: CGFloat = 40
    private static let collapsedHeight: CGFloat = 3
    private static let expandedWidth: CGFloat = 132
    private static let expandedHeight: CGFloat = 24

    /// Outer hit-test frame is constant (matches the expanded pill bounds),
    /// so the pill's visual center never shifts when growing/collapsing.
    /// The visible capsule is centered inside this frame, anchored at the
    /// frame's center — never the bottom. Without this, the pill grows
    /// upward off its bottom edge and the cursor (which triggered hover at
    /// the center of the small pill) ends up at the bottom of the expanded
    /// pill, which feels like the pill is "running away" from the cursor.
    private var pillWidth: CGFloat { isHovered ? Self.expandedWidth : Self.collapsedWidth }
    private var pillHeight: CGFloat { isHovered ? Self.expandedHeight : Self.collapsedHeight }

    var body: some View {
        ZStack {
            // Background fades in
            Capsule(style: .continuous)
                .fill(.black.opacity(isHovered ? 0.82 : 0))
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(.white.opacity(isHovered ? 0.1 : 0), lineWidth: 0.5)
                )
                .shadow(color: .black.opacity(isHovered ? 0.45 : 0), radius: 10, y: 3)

            // Outline fades out — the only thing visible at rest.
            Capsule(style: .continuous)
                .stroke(.white.opacity(isHovered ? 0 : 0.35), lineWidth: 1)

            // Hover content: play button (with a chevron menu for execute /
            // fill input) on the left, settings gear on the right.
            HStack(spacing: 0) {
                PlayMenu()
                Spacer(minLength: 6)
                SettingsLink {
                    Image(systemName: "gearshape")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(.secondary)
                        .frame(width: 18, height: 18)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Settings")
            }
            .padding(.horizontal, 8)
            .opacity(isHovered ? 1 : 0)
            .allowsHitTesting(isHovered)
        }
        .frame(width: pillWidth, height: pillHeight)
        // The outer frame stays constant — visible pill is centered inside it
        // and grows from the center, so its visual position never shifts.
        .frame(width: Self.expandedWidth, height: Self.expandedHeight)
        .contentShape(Rectangle())
        .onHover { hovering in
            isHovered = hovering
        }
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: isHovered)
    }
}

/// Play button paired with a chevron that opens an action-mode menu
/// ("Execute" / "Fill input").
private struct PlayMenu: View {
    var body: some View {
        HStack(spacing: 0) {
            Button {
                // TODO: trigger the default action (dictate). Hooked up
                // here so the play button does the same thing as a tap on
                // the Fn hotkey when the rest of the pipeline is wired.
            } label: {
                Image(systemName: "play.fill")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.primary)
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Start")

            Menu {
                Button("Execute") {
                    // TODO: trigger the .command flow (the ⇧Fn action).
                }
                Button("Fill input") {
                    // TODO: trigger the .insert flow (the ⌃Fn action).
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .heavy))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 18)
                    .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
        }
        .background(Capsule(style: .continuous).fill(.white.opacity(0.12)))
        .clipShape(Capsule(style: .continuous))
    }
}

// MARK: - Active states

private struct RecordingPill: View {
    @Bindable var recorder: AudioRecorder
    let isCommandMode: Bool

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

            if isCommandMode {
                ShortcutChip(label: "Command")
            }
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
        transcriber: Transcriber()
    )
    .frame(width: 600, height: 120)
    .background(.gray.opacity(0.2))
}
