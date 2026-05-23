import Foundation

/// Pure transformation: AppState + AudioRecorder + Transcriber → `Mode`.
///
/// The pill's visual state is a strict priority-ordered switch over the
/// observable inputs. Keeping the priority list in a struct (not a
/// computed property inside the view) means:
///   1. It's unit-testable without instantiating SwiftUI.
///   2. Adding a new mode (e.g., "Downloading model") happens in one
///      place, not scattered across the view's switch statement.
///   3. The view stays a thin presentation layer that just renders `Mode`.
enum PanelViewModel {
    enum Mode: Equatable {
        case idle
        case recording
        case processing(label: String)
        case transcript(String)
        case commandResult(AppState.CommandResult)
    }

    /// Compute the current display mode from observable sources. Priority
    /// (highest first): recording > transcribing > executingCommand >
    /// polishing > downloadingModel > slowLoadingModel > commandResult >
    /// transcript > idle.
    ///
    /// Why this order:
    ///   - Recording always wins — the user is actively speaking, the pill
    ///     must reflect that immediately.
    ///   - Transcribing/Executing/Polishing are post-recording steps; only
    ///     one is active at a time. Whichever is active wins.
    ///   - Downloading shows explicit progress (large first-time fetch); the
    ///     user benefits from seeing the percentage.
    ///   - `.loading` (CoreML / ANE warm-up) is shown ONLY when it's been
    ///     running for more than `loadingIndicatorGrace`. Fast loads (the
    ///     warm cache case) stay invisible — the user never sees a pill flash
    ///     for the typical 1-3s warmup. Slow cold loads, which we've measured
    ///     at 60-150s on a fresh machine, get a pill that says "Warming up
    ///     Whisper…" so users don't think the app is broken when they try
    ///     to record and get a modelNotLoaded error.
    ///   - CommandResult and Transcript are mutually exclusive outcomes
    ///     and live for a few seconds before auto-clearing.
    ///
    /// `loadingElapsedSeconds` is nil when the transcriber isn't in `.loading`
    /// (so it's only positive while loading is in flight). The view layer
    /// computes it from `Date().timeIntervalSince(transcriber.loadingStartedAt)`
    /// and re-renders periodically while the gate is in play.
    static func mode(
        recorderState: AudioRecorder.State,
        transcriberState: Transcriber.State,
        isExecutingCommand: Bool,
        isPolishing: Bool,
        commandResult: AppState.CommandResult?,
        transcript: String?,
        loadingElapsedSeconds: TimeInterval? = nil
    )
        -> Mode
    {
        if recorderState == .recording {
            return .recording
        }
        if case .transcribing = transcriberState {
            return .processing(label: "Transcribing")
        }
        if isExecutingCommand {
            return .processing(label: "Executing")
        }
        if isPolishing {
            return .processing(label: "Polishing")
        }
        if case let .downloading(_, progress) = transcriberState {
            return .processing(label: "Downloading · \(Int(progress * 100))%")
        }
        if
            case .loading = transcriberState,
            let elapsed = loadingElapsedSeconds,
            elapsed >= loadingIndicatorGrace
        {
            return .processing(label: "Warming up Whisper…")
        }
        if let result = commandResult {
            return .commandResult(result)
        }
        if let text = transcript, !text.isEmpty {
            return .transcript(text)
        }
        return .idle
    }

    /// Seconds of unfinished model load before the "Warming up Whisper…"
    /// pill appears. Short enough that a stuck cold load (we've seen 2+
    /// minutes on a fresh machine) becomes visible quickly; long enough
    /// that a fast warmup never flashes a transient pill at the user.
    static let loadingIndicatorGrace: TimeInterval = 8
}
