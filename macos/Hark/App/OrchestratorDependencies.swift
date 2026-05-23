import Foundation

/// Protocols that abstract every external surface `RecordingOrchestrator`
/// touches. Production code uses the concrete `AudioRecorder`,
/// `Transcriber`, `AgentSidecar`, `HotkeyManager`, `PermissionsManager`
/// directly via these protocols. Tests pass in mocks.
///
/// Each protocol is intentionally narrow — it exposes ONLY what the
/// orchestrator needs, not the full surface of the underlying class.
/// Adding a method here means adding a real-system path and a mock path,
/// which forces us to think about the test plan when extending.
@MainActor
protocol AudioRecording: AnyObject {
    var state: AudioRecorder.State { get }
    func start() throws
    func stop() -> [Float]
}

@MainActor
protocol Transcribing: AnyObject {
    func transcribe(samples: [Float]) async throws -> String
    func cancelInFlight()
    /// Pre-load and warm CoreML models so the first transcribe call doesn't
    /// pay the ~15-20s ANE wake-up cost. Fire-and-forget; the production
    /// implementation logs failures internally.
    func bootstrap()
}

@MainActor
protocol SidecarRequesting: AnyObject {
    func request<R: Decodable>(
        method: String,
        params: some Encodable,
        result: R.Type,
        timeout: TimeInterval
    ) async throws
        -> R
}

@MainActor
protocol HotkeyState: AnyObject {
    var mode: HotkeyMode { get }
    var currentTrigger: HotkeyTrigger { get }
    /// Reinstall (or re-enable) the CGEvent tap. Called from
    /// `PermissionsManager.onPermissionGranted` so the global hotkey
    /// auto-revives the moment the user grants Accessibility / Input
    /// Monitoring — no app restart required.
    func installIfNeeded()
}

@MainActor
protocol PermissionGate: AnyObject {
    var allGranted: Bool { get }
    func refresh()
    /// Trigger the system microphone permission prompt. Idempotent —
    /// no-ops once the user has granted or denied.
    func requestMicrophone() async
}

// MARK: - Conformances of the concrete classes

extension AudioRecorder: AudioRecording {}
extension Transcriber: Transcribing {}
extension AgentSidecar: SidecarRequesting {}
extension HotkeyManager: HotkeyState {}
extension PermissionsManager: PermissionGate {}
