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
    /// polishing > downloadingModel > commandResult > transcript > idle.
    ///
    /// Why this order:
    ///   - Recording always wins — the user is actively speaking, the pill
    ///     must reflect that immediately.
    ///   - Transcribing/Executing/Polishing are post-recording steps; only
    ///     one is active at a time. Whichever is active wins.
    ///   - Downloading shows explicit progress (large first-time fetch); the
    ///     user benefits from seeing the percentage.
    ///   - `.loading` (CoreML / ANE warm-up) is DELIBERATELY NOT shown here.
    ///     Prewarm runs in the background at launch and can take 60-120s on
    ///     a cold machine — there's no progress indicator, and surfacing a
    ///     stuck-looking spinner for that long reads as "the app is broken."
    ///     If the user records before the model is ready, the orchestrator
    ///     throws `modelNotLoaded` and the error pill explains "Whisper
    ///     model isn't loaded yet" — clearer signal than an indefinite
    ///     spinner.
    ///   - CommandResult and Transcript are mutually exclusive outcomes
    ///     and live for a few seconds before auto-clearing.
    static func mode(
        recorderState: AudioRecorder.State,
        transcriberState: Transcriber.State,
        isExecutingCommand: Bool,
        isPolishing: Bool,
        commandResult: AppState.CommandResult?,
        transcript: String?
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
        if let result = commandResult {
            return .commandResult(result)
        }
        if let text = transcript, !text.isEmpty {
            return .transcript(text)
        }
        return .idle
    }
}
