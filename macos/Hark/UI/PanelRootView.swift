import OSLog
import SwiftUI

private let panelLogger = Logger(subsystem: "co.milbo.hark", category: "Panel")

/// Wispr Flow-style pill UI. The panel itself is generously sized so
/// every state (idle, recording, transcript, command result) fits
/// without resizing the underlying NSPanel; this view aligns the
/// visible pill to the user-chosen edge inside that frame.
///
/// - Idle: barely-there capsule outline (~40×3); hover hit area matches.
/// - Idle + hover: expands to a compact strip with record / gear / help.
/// - Recording: pulsing red dot + duration + mini bars
/// - Transcribing / loading: spinner + label
/// - Transcript ready: text + copy + dismiss
struct PanelRootView: View {
    @Bindable var appState: AppState
    @Bindable var recorder: AudioRecorder
    @Bindable var transcriber: Transcriber
    @Bindable var positionModel: PillPositionModel
    let actions: PanelActions
    /// Called when the visible pill's bounds change. The hosting view
    /// uses the rect to restrict mouse hit-testing to just the pill —
    /// clicks on the rest of the panel pass through to apps below.
    let onPillBoundsChanged: (CGRect) -> Void

    /// Shared namespace for matchedGeometryEffect so the pill's background
    /// capsule smoothly resizes between hover-state (112pt wide) and
    /// recording-state (76pt wide) — instead of cross-fading two
    /// independently-sized views.
    @Namespace private var pillBackground

    /// Coordinate-space name used by the pill content to report its
    /// frame in the panel's local coordinates. Kept private + named so
    /// other views can't accidentally read into it.
    private static let panelCoordSpace = "co.milbo.hark.pillPanel"

    /// Seconds elapsed since the transcriber entered `.loading`. Ticks
    /// once per second while a load is in flight; SwiftUI re-evaluates
    /// `mode` on every change so the "Warming up Whisper…" pill appears
    /// exactly when `PanelViewModel.loadingIndicatorGrace` is crossed.
    @State private var loadingElapsed: TimeInterval = 0

    var body: some View {
        ZStack(alignment: alignment) {
            // A fully transparent backdrop so the ZStack actually fills
            // the panel — without it, alignment doesn't have a frame to
            // anchor to and the pill renders at the natural origin.
            Color.clear
            content
                .padding(.bottom, 6)
                .padding(.horizontal, edgePadding)
                .scaleEffect(positionModel.isDragging ? 1.03 : 1)
                .shadow(
                    color: .black.opacity(positionModel.isDragging ? 0.55 : 0),
                    radius: positionModel.isDragging ? 18 : 0,
                    y: positionModel.isDragging ? 6 : 0
                )
                .animation(
                    .spring(response: 0.32, dampingFraction: 0.86),
                    value: mode
                )
                .animation(
                    .spring(response: 0.28, dampingFraction: 0.82),
                    value: positionModel.isDragging
                )
                .background(
                    GeometryReader { proxy in
                        Color.clear
                            .preference(
                                key: PillBoundsKey.self,
                                value: proxy.frame(in: .named(Self.panelCoordSpace))
                            )
                    }
                )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .coordinateSpace(name: Self.panelCoordSpace)
        .onPreferenceChange(PillBoundsKey.self) { rect in
            // PreferenceKey callbacks come in on the main actor in
            // current SwiftUI, but the closure is `@Sendable` typed —
            // hop explicitly so Swift 6 strict concurrency stays happy.
            let captured = rect
            Task { @MainActor in onPillBoundsChanged(captured) }
        }
        .task(id: transcriber.loadingStartedAt) {
            // Drive the 1Hz tick that promotes a long-running load
            // into the "Warming up…" pill. The task is bound to
            // `loadingStartedAt` so it auto-cancels when load finishes
            // (started→nil) or restarts (nil→started) without us
            // hand-rolling timer lifecycle.
            guard let started = transcriber.loadingStartedAt else {
                loadingElapsed = 0
                return
            }
            while !Task.isCancelled {
                loadingElapsed = Date().timeIntervalSince(started)
                try? await Task.sleep(for: .seconds(1))
            }
        }
    }

    @ViewBuilder private var content: some View {
        switch mode {
        case .recording:
            RecordingPill(
                recorder: recorder,
                isCommandMode: false,
                actions: actions,
                backgroundNamespace: pillBackground,
                isDraggable: false
            )
            .transition(.opacity)
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
            IdlePillView(
                actions: actions,
                recorder: recorder,
                backgroundNamespace: pillBackground,
                isDraggable: true
            )
            .transition(.opacity)
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
            transcript: appState.transcript,
            loadingElapsedSeconds: transcriber.loadingStartedAt == nil ? nil : loadingElapsed
        )
    }

    /// ZStack alignment derived from the anchor. The visible pill ends
    /// up at the matching edge of the panel's wide stage, so the panel
    /// origin + this alignment together place the pill where the user
    /// parked it on screen.
    private var alignment: Alignment {
        switch positionModel.anchor {
        case .left: .bottomLeading
        case .center: .bottom
        case .right: .bottomTrailing
        }
    }

    /// Horizontal padding applied to the content for `.left` and
    /// `.right` anchors so the visible pill doesn't sit flush against
    /// the panel edge (which would visually touch the screen edge once
    /// the panel is positioned at the same edge).
    private var edgePadding: CGFloat {
        switch positionModel.anchor {
        case .left, .right: 8
        case .center: 0
        }
    }
}

// MARK: - Hit-test plumbing

/// SwiftUI preference key used by the active pill to report its
/// rendered frame (in the panel's coordinate space) up to the root,
/// which forwards it to `PassThroughHostingView` for hit-test masking.
struct PillBoundsKey: PreferenceKey {
    static let defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        // Only one pill is ever visible at a time; last-write-wins keeps
        // the rect tracking the most recently laid-out pill.
        value = nextValue()
    }
}

// MARK: - Active states

private struct RecordingPill: View {
    @Bindable var recorder: AudioRecorder
    let isCommandMode: Bool
    let actions: PanelActions
    let backgroundNamespace: Namespace.ID
    let isDraggable: Bool

    var body: some View {
        // Entire pill is the stop button. The trigger argument is irrelevant
        // here — togglePanelRecording detects the active recording and stops
        // it; nothing new gets started.
        Button {
            actions.toggleRecording(.dictate)
        } label: {
            ZStack {
                // matchedGeometryEffect against the IdlePillView's expanded
                // background — SwiftUI interpolates frame between the two
                // (hover 112pt → recording 76pt) so the user sees the pill
                // SMOOTHLY SHRINK on record-start and grow back when the
                // recording ends. Pairs with the spring animation set on
                // the parent's `.animation(_:value: mode)` modifier.
                PillBackground()
                    .matchedGeometryEffect(id: "pill", in: backgroundNamespace)

                // Stop button + timer centered AS A GROUP inside the pill.
                // HStack is sized to its content (no Spacer), and the
                // surrounding ZStack centers it both axes — so the two
                // elements stay snug against each other and the pair sits
                // dead-center in the capsule.
                HStack(spacing: 6) {
                    ZStack {
                        // Volume-reactive halo. At silence (level=0)
                        // opacity is 0 so NO border shows — only the
                        // solid 12pt dot. As mic input rises, the halo
                        // fades in AND scales outward — real-time level
                        // cue tied to the stop button.
                        Circle()
                            .stroke(
                                .red.opacity(0.7 * Double(min(recorder.level * 5, 1))),
                                lineWidth: 5
                            )
                            .frame(width: 12, height: 12)
                            .scaleEffect(1 + CGFloat(min(recorder.level * 5, 1.2)))
                            .animation(.easeOut(duration: 0.12), value: recorder.level)
                        Circle()
                            .fill(.red)
                            .frame(width: 12, height: 12)
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
                }

                if isCommandMode {
                    HStack {
                        Spacer()
                        ShortcutChip(label: "Command")
                    }
                    .padding(.horizontal, PanelLayout.interiorPadding)
                }
            }
            // Snug recording size — just record button + centered time. The
            // matched-geometry animation interpolates the pill's frame
            // between hover (112pt) and recording (76pt) for a smooth
            // shrink/grow on transition.
            .frame(width: PanelLayout.recordingWidth, height: PanelLayout.expandedHeight)
            .contentShape(Capsule(style: .continuous))
        }
        .buttonStyle(.plain)
        .help("Click to stop")
        .pillDraggable(isDraggable, actions: actions)
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

// MARK: - Shared layout

/// Single source of truth for the pill's geometry. Hover and recording
/// states share the same height + interior padding; their widths differ
/// (recording is snugger since it only shows record button + time), and
/// matchedGeometryEffect on the background interpolates the width during
/// the transition for a smooth shrink/grow.
enum PanelLayout {
    static let expandedWidth: CGFloat = 112
    static let recordingWidth: CGFloat = 76
    static let expandedHeight: CGFloat = 24
    /// Match horizontal to vertical so content sits the same distance
    /// from every edge of the capsule.
    static let interiorPadding: CGFloat = 3
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

struct PillBackground: View {
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
        positionModel: PillPositionModel(),
        actions: PanelActions(
            toggleRecording: { _ in },
            cancelProcessing: {},
            beginDrag: {},
            updateDrag: { _ in },
            endDrag: { _ in }
        ),
        onPillBoundsChanged: { _ in }
    )
    .frame(width: 600, height: 120)
    .background(.gray.opacity(0.2))
}
