@testable import Hark
import XCTest

// Shared test infrastructure for the recording-orchestrator suites.
// Two suites live next to each other to stay under SwiftLint's
// file_length and type_body_length thresholds:
//
//   - `RecordingOrchestratorTests` — state-machine + start/stop pairing
//   - `RecordingOrchestratorPipelineTests` — finalize-time branching,
//     error recovery, trigger latching, usage stats
//
// Both build orchestrators via `OrchestratorFixture.make(...)`, which
// returns a value-type bundle so callers can `let fix = .make(); fix.x`
// instead of unpacking a giant tuple (which trips the large_tuple lint).

@MainActor
struct OrchestratorFixture {
    let orchestrator: RecordingOrchestrator
    let appState: AppState
    let hotkey: MockHotkey
    let recorder: MockRecorder
    let transcriber: MockTranscriber
    let sidecar: MockSidecar
    let permissions: MockPermissions
    let needsOnboardingCalls: Box<Int>

    /// Build an orchestrator pre-wired with mock dependencies. Each mock
    /// is created if not provided; callers override the ones they care
    /// about and rely on defaults for the rest.
    static func make(
        appState: AppState? = nil,
        hotkey: MockHotkey? = nil,
        recorder: MockRecorder? = nil,
        transcriber: MockTranscriber? = nil,
        sidecar: MockSidecar? = nil,
        permissions: MockPermissions? = nil,
        onNeedsOnboarding: (() -> Void)? = nil
    )
        -> Self
    {
        let state = appState ?? AppState()
        let h = hotkey ?? MockHotkey()
        let r = recorder ?? MockRecorder()
        let t = transcriber ?? MockTranscriber()
        let s = sidecar ?? MockSidecar()
        let p = permissions ?? MockPermissions(allGranted: true)
        let calls = Box(0)
        let orch = RecordingOrchestrator(
            appState: state,
            hotkey: h,
            recorder: r,
            transcriber: t,
            sidecar: s,
            permissions: p,
            needsOnboarding: {
                calls.value += 1
                onNeedsOnboarding?()
            }
        )
        return Self(
            orchestrator: orch,
            appState: state,
            hotkey: h,
            recorder: r,
            transcriber: t,
            sidecar: s,
            permissions: p,
            needsOnboardingCalls: calls
        )
    }
}

// MARK: - Generic helpers

final class Box<T> {
    var value: T
    init(_ value: T) {
        self.value = value
    }
}

/// Poll a predicate until it returns true or the deadline expires.
/// Robust on slow CI runners — unlike a fixed-duration sleep, this
/// returns as SOON as the condition holds, so a fast machine completes
/// in milliseconds and a slow machine still gets the full timeout window.
@MainActor
func waitFor(
    timeout: TimeInterval = 5,
    _ condition: @escaping @MainActor () -> Bool
) async {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if condition() { return }
        try? await Task.sleep(nanoseconds: 10_000_000) // 10ms
    }
    _ = condition()
}

// MARK: - Mock implementations

@MainActor
final class MockHotkey: HotkeyState {
    var mode: HotkeyMode
    var currentTrigger: HotkeyTrigger
    private(set) var installCalls = 0

    init(mode: HotkeyMode = .hold, currentTrigger: HotkeyTrigger = .dictate) {
        self.mode = mode
        self.currentTrigger = currentTrigger
    }

    func installIfNeeded() {
        installCalls += 1
    }
}

@MainActor
final class MockRecorder: AudioRecording {
    var state: AudioRecorder.State
    var samples: [Float]
    var startError: Error?
    private(set) var startCalls = 0
    private(set) var stopCalls = 0

    init(initialState: AudioRecorder.State = .idle, samples: [Float] = []) {
        state = initialState
        self.samples = samples
    }

    func start() throws {
        startCalls += 1
        if let startError {
            throw startError
        }
        state = .recording
    }

    func stop() -> [Float] {
        stopCalls += 1
        state = .idle
        return samples
    }
}

@MainActor
final class MockTranscriber: Transcribing {
    var transcribeResult: Result<String, Error> = .success("")
    private(set) var transcribeCalls = 0
    private(set) var cancelCalls = 0
    private(set) var bootstrapCalls = 0

    func transcribe(samples: [Float]) async throws -> String {
        transcribeCalls += 1
        _ = samples
        switch transcribeResult {
        case let .success(text): return text
        case let .failure(error): throw error
        }
    }

    func cancelInFlight() {
        cancelCalls += 1
    }

    func bootstrap() {
        bootstrapCalls += 1
    }
}

@MainActor
final class MockSidecar: SidecarRequesting {
    struct PolishUsage {
        let inputTokens: Int
        let outputTokens: Int
        let cacheReadTokens: Int
        let cacheCreationTokens: Int
    }

    struct ExecuteResultPayload {
        let summary: String
        let succeeded: Bool
        let usage: PolishUsage?
    }

    var polishedText: String = ""
    var polishError: Error?
    var polishUsage: PolishUsage?
    var executeResult: ExecuteResultPayload?
    var executeError: Error?

    private(set) var requestedMethods: [String] = []
    private(set) var requestedTimeouts: [String: TimeInterval] = [:]

    /// Optional error to inject for a specific method. Lets tests
    /// validate that the orchestrator's error envelope handling routes
    /// `.server(_, code:)` errors to the right user-visible state.
    var errorByMethod: [String: Error] = [:]

    func request<R: Decodable>(
        method: String,
        params _: some Encodable,
        result _: R.Type,
        timeout: TimeInterval
    ) async throws
        -> R
    {
        requestedMethods.append(method)
        requestedTimeouts[method] = timeout

        if let injected = errorByMethod[method] {
            throw injected
        }

        switch method {
        case "polishTranscript":
            return try handlePolish()
        case "executeCommand":
            return try handleExecute()
        default:
            throw NSError(domain: "MockSidecar", code: 1)
        }
    }

    private func handlePolish<R: Decodable>() throws -> R {
        if let polishError { throw polishError }
        var dict: [String: Any] = [
            "polished": polishedText,
            "changed": true
        ]
        if let usage = polishUsage {
            dict["usage"] = [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheReadTokens": usage.cacheReadTokens,
                "cacheCreationTokens": usage.cacheCreationTokens
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(R.self, from: data)
    }

    private func handleExecute<R: Decodable>() throws -> R {
        if let executeError { throw executeError }
        guard let result = executeResult else {
            throw NSError(domain: "MockSidecar", code: 0)
        }
        var dict: [String: Any] = [
            "summary": result.summary,
            "succeeded": result.succeeded
        ]
        if let usage = result.usage {
            dict["usage"] = [
                "inputTokens": usage.inputTokens,
                "outputTokens": usage.outputTokens,
                "cacheReadTokens": usage.cacheReadTokens,
                "cacheCreationTokens": usage.cacheCreationTokens
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(R.self, from: data)
    }
}

@MainActor
final class MockPermissions: PermissionGate {
    var allGranted: Bool
    private(set) var refreshCalls = 0
    private(set) var requestMicCalls = 0

    init(allGranted: Bool) {
        self.allGranted = allGranted
    }

    func refresh() {
        refreshCalls += 1
    }

    func requestMicrophone() async {
        requestMicCalls += 1
    }
}
