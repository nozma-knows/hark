@testable import Hark
import XCTest

/// Priority-ordered switch in `PanelViewModel.mode` is the single source
/// of truth for which pill the user sees. These tests pin down every
/// branch so a future refactor can't silently flip the priority order
/// (e.g., making "Polishing" win over "Recording" while the user is
/// still talking would be a major UX regression).
@MainActor
final class PanelViewModelTests: XCTestCase {
    // MARK: - Highest-priority wins: recording

    func testRecordingBeatsEverything() {
        let mode = PanelViewModel.mode(
            recorderState: .recording,
            transcriberState: .transcribing(.default),
            isExecutingCommand: true,
            isPolishing: true,
            commandResult: .init(summary: "anything", succeeded: true),
            transcript: "anything"
        )
        XCTAssertEqual(mode, .recording)
    }

    // MARK: - Transcribing wins after recording stops

    func testTranscribingBeatsExecutingAndPolishing() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .transcribing(.default),
            isExecutingCommand: true,
            isPolishing: true,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Transcribing"))
    }

    func testExecutingBeatsPolishing() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: true,
            isPolishing: true,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Executing"))
    }

    func testPolishingShownWhenOnlyPolishing() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: false,
            isPolishing: true,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Polishing"))
    }

    // MARK: - Model lifecycle states show only when no real work is in flight

    func testLoadingShownWhenNoActiveWork() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Loading model"))
    }

    func testDownloadingShowsProgress() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .downloading(.default, progress: 0.42),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Downloading · 42%"))
    }

    // MARK: - Terminal states (after pipeline completes)

    func testCommandResultBeatsTranscript() {
        let result = AppState.CommandResult(summary: "Opened Chrome", succeeded: true)
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: result,
            transcript: "this transcript should not show"
        )
        XCTAssertEqual(mode, .commandResult(result))
    }

    func testTranscriptShownWhenNoCommandResult() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: "Hello world"
        )
        XCTAssertEqual(mode, .transcript("Hello world"))
    }

    func testEmptyTranscriptDoesNotMaskIdle() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: ""
        )
        XCTAssertEqual(mode, .idle)
    }

    // MARK: - Idle fallback

    func testFullyIdle() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .unloaded,
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .idle)
    }

    // MARK: - Boundary cases

    /// 0% download progress is a legitimate moment-in-time state — the
    /// download has started but no bytes have flowed yet. Pill must
    /// render `Downloading · 0%`, not error or skip.
    func testDownloadingZeroPercent() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .downloading(.default, progress: 0),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Downloading · 0%"))
    }

    /// Floating-point edge: 0.999 should floor to 99% (Int cast), not
    /// round to 100%. Documents the "user sees the final percentage tick
    /// up to 100% only when the download truly completes" expectation.
    func testDownloadingNearComplete() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .downloading(.default, progress: 0.999),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .processing(label: "Downloading · 99%"))
    }

    /// Failed model load — we have no dedicated pill for this state
    /// today (treated as idle). Pinning the behavior so a future commit
    /// that adds a `.failed` UI surface doesn't silently regress idle.
    func testFailedTranscriberStateFallsThroughToIdle() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .failed("model load failed"),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .idle)
    }

    /// While the model is loading, an active recording still wins the
    /// pill — the user is speaking RIGHT NOW and shouldn't see a stale
    /// "Loading model" label until they release.
    func testRecordingWinsOverModelLoading() {
        let mode = PanelViewModel.mode(
            recorderState: .recording,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .recording)
    }

    /// `nil` transcript vs empty-string transcript — only the empty
    /// string variant has historically been ambiguous (it's truthy as
    /// a value but represents "nothing to show"). Pin both paths.
    func testNilTranscriptFallsThroughToIdle() {
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .ready(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil
        )
        XCTAssertEqual(mode, .idle)
    }
}
