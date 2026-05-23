@testable import Hark
import XCTest

/// State-machine coverage: permission gating, start/stop pairing across
/// the hotkey and pill entry points, start-time side effects, and the
/// manual-cancel escape hatch. Pipeline (transcribe → polish/execute →
/// deliver) is covered separately in `RecordingOrchestratorPipelineTests`.
@MainActor
final class RecordingOrchestratorTests: XCTestCase {
    // MARK: - Permission gating

    func testHotkeyDownRoutesToOnboardingWhenPermissionsMissing() {
        let perms = MockPermissions(allGranted: false)
        let fix = OrchestratorFixture.make(permissions: perms)

        fix.orchestrator.handleHotkeyDown(.dictate)

        XCTAssertEqual(fix.needsOnboardingCalls.value, 1)
        XCTAssertEqual(fix.recorder.startCalls, 0, "recording must not start without permissions")
        XCTAssertEqual(fix.permissions.refreshCalls, 1, "permissions must be re-polled before gating")
    }

    func testPanelTogglePermissionsMissingAlsoGates() {
        let perms = MockPermissions(allGranted: false)
        let fix = OrchestratorFixture.make(permissions: perms)

        fix.orchestrator.togglePanelRecording(.dictate)

        XCTAssertEqual(fix.needsOnboardingCalls.value, 1)
        XCTAssertEqual(fix.recorder.startCalls, 0)
    }

    // MARK: - Start / stop pairing (hotkey)

    func testHotkeyDownStartsRecording() {
        let fix = OrchestratorFixture.make()

        fix.orchestrator.handleHotkeyDown(.dictate)

        XCTAssertEqual(fix.recorder.startCalls, 1)
        XCTAssertNil(fix.appState.transcript)
        XCTAssertFalse(fix.appState.transcriptInsertFailed)
    }

    func testHotkeyDownWhileRecordingStopsInstead() {
        let recorder = MockRecorder(initialState: .recording)
        let fix = OrchestratorFixture.make(recorder: recorder)

        fix.orchestrator.handleHotkeyDown(.dictate)

        // Should stop, not start a second recording. Without this branch,
        // hold-mode tries a second start and the recording becomes
        // unstoppable from the keyboard.
        XCTAssertEqual(fix.recorder.stopCalls, 1)
        XCTAssertEqual(fix.recorder.startCalls, 0)
    }

    func testHotkeyUpStopsInHoldMode() {
        let hk = MockHotkey(mode: .hold, currentTrigger: .dictate)
        let recorder = MockRecorder(initialState: .recording)
        let fix = OrchestratorFixture.make(hotkey: hk, recorder: recorder)

        fix.orchestrator.handleHotkeyUp(.dictate)

        XCTAssertEqual(fix.recorder.stopCalls, 1)
    }

    func testHotkeyUpDoesNothingInToggleMode() {
        let hk = MockHotkey(mode: .toggle, currentTrigger: .dictate)
        let recorder = MockRecorder(initialState: .recording)
        let fix = OrchestratorFixture.make(hotkey: hk, recorder: recorder)

        fix.orchestrator.handleHotkeyUp(.dictate)

        // Toggle mode: key-up is a no-op. User must tap key again to stop.
        XCTAssertEqual(fix.recorder.stopCalls, 0)
    }

    func testHotkeyUpDoesNothingWhenIdle() {
        let hk = MockHotkey(mode: .hold)
        let recorder = MockRecorder(initialState: .idle)
        let fix = OrchestratorFixture.make(hotkey: hk, recorder: recorder)

        fix.orchestrator.handleHotkeyUp(.dictate)

        XCTAssertEqual(fix.recorder.stopCalls, 0)
    }

    func testHotkeyUpDoesNotStopPillInitiatedRecording() {
        let hk = MockHotkey(mode: .hold)
        let recorder = MockRecorder(initialState: .idle)
        let fix = OrchestratorFixture.make(hotkey: hk, recorder: recorder)

        // Start via pill (manual)
        fix.orchestrator.togglePanelRecording(.dictate)
        XCTAssertEqual(fix.recorder.startCalls, 1)
        recorder.state = .recording

        // Fn-up should NOT stop the pill-initiated recording — only a
        // second pill click can.
        fix.orchestrator.handleHotkeyUp(.dictate)
        XCTAssertEqual(fix.recorder.stopCalls, 0)
    }

    // MARK: - Pill toggle

    func testPanelToggleStartsThenStops() {
        let fix = OrchestratorFixture.make()

        fix.orchestrator.togglePanelRecording(.dictate)
        XCTAssertEqual(fix.recorder.startCalls, 1)

        fix.recorder.state = .recording
        fix.orchestrator.togglePanelRecording(.dictate)
        XCTAssertEqual(fix.recorder.stopCalls, 1)
    }

    // MARK: - Start side-effects

    func testStartClearsPreviousTranscriptAndFailureFlag() {
        let fix = OrchestratorFixture.make()
        fix.appState.transcript = "stale transcript"
        fix.appState.transcriptInsertFailed = true

        fix.orchestrator.handleHotkeyDown(.dictate)

        XCTAssertNil(fix.appState.transcript)
        XCTAssertFalse(fix.appState.transcriptInsertFailed)
    }

    func testStartFailureDoesNotCrash() {
        let recorder = MockRecorder()
        recorder.startError = NSError(domain: "test", code: 1)
        let fix = OrchestratorFixture.make(recorder: recorder)

        // Must not throw — orchestrator catches and logs.
        fix.orchestrator.handleHotkeyDown(.dictate)
        XCTAssertEqual(fix.recorder.startCalls, 1)
    }

    // MARK: - Manual cancel

    func testCancelProcessingClearsAllFlags() {
        let fix = OrchestratorFixture.make()
        fix.appState.isPolishing = true
        fix.appState.isExecutingCommand = true

        fix.orchestrator.cancelProcessing()

        XCTAssertFalse(fix.appState.isPolishing)
        XCTAssertFalse(fix.appState.isExecutingCommand)
        XCTAssertEqual(fix.transcriber.cancelCalls, 1)
    }
}
