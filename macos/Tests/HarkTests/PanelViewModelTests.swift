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

    func testLoadingFallsThroughToIdleWhenWithinGrace() {
        // Fast warmups (sub-grace) stay invisible. The pill doesn't flash
        // a transient "Warming up Whisper…" for the typical 1-3s warm-cache
        // load — that would just look like a flicker on every launch.
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil,
            loadingElapsedSeconds: 3
        )
        XCTAssertEqual(mode, .idle)
    }

    func testLoadingShowsPillWhenGraceExceeded() {
        // Cold loads on a fresh machine can take 60-150s. After the grace
        // window (8s), surface a pill so the user knows the app isn't
        // broken — without this they'd see only an "Whisper isn't loaded
        // yet" error pill on first recording attempt with no prior signal.
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil,
            loadingElapsedSeconds: PanelViewModel.loadingIndicatorGrace
        )
        XCTAssertEqual(mode, .processing(label: "Warming up Whisper…"))
    }

    func testLoadingWithoutElapsedDataFallsThroughToIdle() {
        // Defensive: when the caller hasn't wired the elapsed counter
        // yet (or transcriber.loadingStartedAt was nil), don't surface
        // the pill. Production view passes nil in this case; we treat
        // it as "no grace tracking yet" rather than "grace exceeded".
        let mode = PanelViewModel.mode(
            recorderState: .idle,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil,
            loadingElapsedSeconds: nil
        )
        XCTAssertEqual(mode, .idle)
    }

    func testLoadingDoesNotMaskHigherPriorityStates() {
        // Even WITH the grace exceeded, a recording in flight wins.
        let mode = PanelViewModel.mode(
            recorderState: .recording,
            transcriberState: .loading(.default),
            isExecutingCommand: false,
            isPolishing: false,
            commandResult: nil,
            transcript: nil,
            loadingElapsedSeconds: 60
        )
        XCTAssertEqual(mode, .recording)
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

    /// While the model is loading in the background, an active recording
    /// still wins the pill — the user is speaking RIGHT NOW and the
    /// recording UI is the highest-priority state.
    func testRecordingWinsOverBackgroundModelLoading() {
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
