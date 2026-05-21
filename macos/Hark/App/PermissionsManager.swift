import AppKit
import ApplicationServices
import AVFoundation
import Observation

/// Tracks the two macOS permissions Hark needs to function:
/// 1. Microphone — required to record audio for transcription
/// 2. Accessibility — required for the `KeyboardShortcuts` global hotkey
///    (uses a CGEvent tap, which only the system can authorize)
///
/// The system has no notification for either grant flip; callers should invoke
/// `refresh()` whenever the user might have changed Settings (e.g., on
/// `NSApplication.didBecomeActiveNotification`).
@MainActor
@Observable
final class PermissionsManager {
    enum MicrophoneStatus: Equatable {
        case undetermined
        case granted
        case denied
    }

    private(set) var microphone: MicrophoneStatus = .undetermined
    private(set) var accessibilityTrusted: Bool = false

    var allGranted: Bool {
        microphone == .granted && accessibilityTrusted
    }

    init() {
        refresh()
    }

    /// Re-read both permission states from the system. Cheap; safe to call often.
    func refresh() {
        microphone = Self.currentMicrophoneStatus()
        accessibilityTrusted = AXIsProcessTrusted()
    }

    /// Triggers the system prompt for microphone access (idempotent —
    /// silently no-ops if the user has already granted or denied).
    func requestMicrophone() async {
        let granted = await AVCaptureDevice.requestAccess(for: .audio)
        microphone = granted ? .granted : .denied
    }

    /// Triggers the system prompt for Accessibility (the "X would like to
    /// control this computer using accessibility features" dialog). The user
    /// still has to flip the toggle in System Settings; we return only what
    /// AX thinks right now.
    @discardableResult
    func promptAccessibility() -> Bool {
        // The system constant `kAXTrustedCheckOptionPrompt` is a CFStringRef that
        // Swift's strict concurrency model flags as a global var; the literal
        // value is documented and stable, so we use it directly.
        let options: CFDictionary = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        let trusted = AXIsProcessTrustedWithOptions(options)
        accessibilityTrusted = trusted
        return trusted
    }

    func openMicrophoneSettings() {
        openSystemSettings(pane: "Privacy_Microphone")
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }

    private static func currentMicrophoneStatus() -> MicrophoneStatus {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: .granted
        case .denied, .restricted: .denied
        case .notDetermined: .undetermined
        @unknown default: .undetermined
        }
    }
}
