@testable import Hark
import XCTest

/// Covers everything that happens AFTER `recorder.stop()` returns samples:
/// trigger resolution at finalize, dictate vs command branching, polish
/// fallback, error surfacing, and usage accumulation. State-machine
/// coverage (start/stop pairing, gating) lives in
/// `RecordingOrchestratorTests`.
@MainActor
final class RecordingOrchestratorPipelineTests: XCTestCase {
    // MARK: - Dictate path

    func testDictateFinalizeShowsTranscript() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("  Hello world  ")
        let sidecar = MockSidecar()
        sidecar.polishedText = "Hello world."
        let recorder = MockRecorder(initialState: .recording, samples: [0.1, 0.2])
        let fix = OrchestratorFixture.make(recorder: recorder, transcriber: transcriber, sidecar: sidecar)

        fix.orchestrator.handleHotkeyDown(.dictate) // stop, since recording

        await waitFor { fix.appState.transcript != nil }

        XCTAssertEqual(fix.appState.transcript, "Hello world.")
        XCTAssertFalse(fix.appState.isPolishing)
    }

    func testDictateFallsBackToRawWhenPolishFails() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("raw text")
        let sidecar = MockSidecar()
        sidecar.polishError = AgentSidecar.SidecarError.notRunning
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(recorder: recorder, transcriber: transcriber, sidecar: sidecar)

        fix.orchestrator.handleHotkeyDown(.dictate)

        await waitFor { fix.appState.transcript != nil }

        XCTAssertEqual(fix.appState.transcript, "raw text")
    }

    func testEmptySamplesShortCircuits() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("should not be called")
        let recorder = MockRecorder(initialState: .recording, samples: [])
        let fix = OrchestratorFixture.make(recorder: recorder, transcriber: transcriber)

        fix.orchestrator.handleHotkeyDown(.dictate)

        // Negative test: wait briefly for any side effects, then assert
        // NOTHING happened. 200ms is generous — the orchestrator's
        // empty-samples guard runs synchronously before any Task hops.
        try? await Task.sleep(nanoseconds: 200_000_000)

        XCTAssertEqual(transcriber.transcribeCalls, 0, "no samples → no transcribe")
        XCTAssertNil(fix.appState.transcript)
    }

    func testEmptyTranscriptShortCircuits() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("   ")
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(recorder: recorder, transcriber: transcriber)

        fix.orchestrator.handleHotkeyDown(.dictate)
        await waitFor { transcriber.transcribeCalls > 0 }
        try? await Task.sleep(nanoseconds: 100_000_000)

        XCTAssertNil(fix.appState.transcript, "whitespace-only transcript must not show")
    }

    // MARK: - Command path

    func testCommandFinalizeSkipsPolish() async {
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("open chrome")
        let sidecar = MockSidecar()
        sidecar.executeResult = MockSidecar.ExecuteResultPayload(
            summary: "Opened Chrome",
            succeeded: true,
            usage: nil
        )
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(
            hotkey: hk,
            recorder: recorder,
            transcriber: transcriber,
            sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.command)
        await waitFor { fix.appState.commandResult != nil }

        XCTAssertEqual(sidecar.requestedMethods, ["executeCommand"], "command path must NOT polish")
        XCTAssertEqual(fix.appState.commandResult?.summary, "Opened Chrome")
        XCTAssertTrue(fix.appState.commandResult?.succeeded ?? false)
    }

    func testCommandFinalizeUsesLongTimeout() async {
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("run tests")
        let sidecar = MockSidecar()
        sidecar.executeResult = MockSidecar.ExecuteResultPayload(
            summary: "ok", succeeded: true, usage: nil
        )
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(
            hotkey: hk,
            recorder: recorder,
            transcriber: transcriber,
            sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.command)
        await waitFor { sidecar.requestedTimeouts["executeCommand"] != nil }

        // executeCommand should pass a 60s timeout — Claude can think for
        // a while. polishTranscript uses 8s.
        XCTAssertEqual(sidecar.requestedTimeouts["executeCommand"], 60)
    }

    func testCommandFailureSurfacesAsErrorPill() async {
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("do something")
        let sidecar = MockSidecar()
        sidecar.executeError = AgentSidecar.SidecarError.notRunning
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(
            hotkey: hk, recorder: recorder, transcriber: transcriber, sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.command)
        await waitFor { fix.appState.commandResult != nil }

        XCTAssertFalse(fix.appState.commandResult?.succeeded ?? true)
    }

    /// Server envelope: AgentSidecar mapped `{ok:false, error, code}` to
    /// `SidecarError.server(message, code)`. Orchestrator must surface
    /// the code-bearing failure via the red command-result pill.
    func testServerEnvelopeErrorSurfacesAsErrorPill() async {
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("do the thing")
        let sidecar = MockSidecar()
        sidecar.errorByMethod["executeCommand"] = AgentSidecar.SidecarError.server(
            message: "unauthorized — no auth detected",
            code: "no_auth"
        )
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(
            hotkey: hk, recorder: recorder, transcriber: transcriber, sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.command)
        await waitFor { fix.appState.commandResult != nil }

        guard let result = fix.appState.commandResult else {
            XCTFail("expected commandResult to be set")
            return
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(
            result.summary.contains("unauthorized") || result.summary.contains("no_auth"),
            "error pill should surface the server reason; got: \(result.summary)"
        )
    }

    func testSidecarTimeoutSurfacesAsErrorPill() async {
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("run something slow")
        let sidecar = MockSidecar()
        sidecar.errorByMethod["executeCommand"] = AgentSidecar.SidecarError.timedOut(
            method: "executeCommand",
            after: 60
        )
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(
            hotkey: hk, recorder: recorder, transcriber: transcriber, sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.command)
        await waitFor { fix.appState.commandResult != nil }

        guard let result = fix.appState.commandResult else {
            XCTFail("expected commandResult to be set")
            return
        }
        XCTAssertFalse(result.succeeded)
        XCTAssertTrue(
            result.summary.lowercased().contains("timed out") || result.summary.contains("timedOut"),
            "timeout pill should surface the timeout reason; got: \(result.summary)"
        )
    }

    // MARK: - Transcribe failure recovery

    func testTranscribeFailureClearsProcessingAndShowsErrorPill() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .failure(TranscriberError.timedOut)
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let fix = OrchestratorFixture.make(recorder: recorder, transcriber: transcriber)

        // pre-set processing flags to make sure they get cleared
        fix.appState.isPolishing = true
        fix.appState.isExecutingCommand = true

        fix.orchestrator.handleHotkeyDown(.dictate)
        await waitFor { fix.appState.commandResult != nil }

        XCTAssertFalse(fix.appState.isPolishing)
        XCTAssertFalse(fix.appState.isExecutingCommand)
        XCTAssertNotNil(fix.appState.commandResult)
        XCTAssertFalse(fix.appState.commandResult?.succeeded ?? true)
    }

    // MARK: - Trigger resolution at finalize

    func testManualTriggerWinsOverLiveModifiers() async {
        // Start via pill in command mode; live trigger says dictate.
        // The manual trigger must win.
        let hk = MockHotkey(currentTrigger: .dictate)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("run")
        let sidecar = MockSidecar()
        sidecar.executeResult = MockSidecar.ExecuteResultPayload(
            summary: "ok", succeeded: true, usage: nil
        )
        let recorder = MockRecorder(initialState: .idle)
        let fix = OrchestratorFixture.make(
            hotkey: hk, recorder: recorder, transcriber: transcriber, sidecar: sidecar
        )

        fix.orchestrator.togglePanelRecording(.command) // manual=command
        recorder.state = .recording
        recorder.samples = [0.1]
        fix.orchestrator.togglePanelRecording(.command) // stop
        await waitFor { !sidecar.requestedMethods.isEmpty }

        XCTAssertEqual(
            sidecar.requestedMethods,
            ["executeCommand"],
            "manual trigger must win over live hotkey trigger"
        )
    }

    func testHotkeyDrivenTriggerUsesLiveCurrentTrigger() async {
        // Hotkey path: no manualRecordingTrigger set. The live
        // currentTrigger at stop time is what gets used.
        let hk = MockHotkey(currentTrigger: .command)
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("execute me")
        let sidecar = MockSidecar()
        sidecar.executeResult = MockSidecar.ExecuteResultPayload(
            summary: "ok", succeeded: true, usage: nil
        )
        let recorder = MockRecorder(initialState: .idle)
        let fix = OrchestratorFixture.make(
            hotkey: hk, recorder: recorder, transcriber: transcriber, sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.dictate) // start
        recorder.state = .recording
        recorder.samples = [0.1]
        // live trigger flipped to command by the time the user releases
        hk.currentTrigger = .command
        fix.orchestrator.handleHotkeyDown(.dictate) // stop (recording)
        await waitFor { !sidecar.requestedMethods.isEmpty }

        XCTAssertEqual(
            sidecar.requestedMethods,
            ["executeCommand"],
            "hotkey path must use the live currentTrigger at stop"
        )
    }

    // MARK: - Usage accumulation

    func testUsageStatsAccumulateAcrossPolish() async {
        let transcriber = MockTranscriber()
        transcriber.transcribeResult = .success("hello")
        let sidecar = MockSidecar()
        sidecar.polishedText = "Hello."
        sidecar.polishUsage = .init(
            inputTokens: 100,
            outputTokens: 50,
            cacheReadTokens: 5,
            cacheCreationTokens: 2
        )
        let recorder = MockRecorder(initialState: .recording, samples: [0.1])
        let appState = AppState()
        // AppState.claudeUsage hydrates from UserDefaults on init, which
        // means real-app accumulated usage leaks into the test. Reset to a
        // fresh counter so we can assert the *delta* this pipeline added.
        appState.claudeUsage = ClaudeUsage()
        let fix = OrchestratorFixture.make(
            appState: appState,
            recorder: recorder,
            transcriber: transcriber,
            sidecar: sidecar
        )

        fix.orchestrator.handleHotkeyDown(.dictate)
        await waitFor { fix.appState.transcript != nil }

        XCTAssertEqual(fix.appState.claudeUsage.inputTokens, 100)
        XCTAssertEqual(fix.appState.claudeUsage.outputTokens, 50)
        XCTAssertEqual(fix.appState.claudeUsage.cacheReadTokens, 5)
        XCTAssertEqual(fix.appState.claudeUsage.cacheCreationTokens, 2)
        XCTAssertEqual(fix.appState.claudeUsage.requestCount, 1)
    }
}
