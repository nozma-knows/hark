import AppKit
import ApplicationServices
import AVFoundation
import IOKit.hid
import Observation
import OSLog

/// Tracks the three macOS permissions Hark needs to function:
/// 1. Microphone — required to record audio for transcription
/// 2. Accessibility — required to call CGEvent.tapCreate
/// 3. Input Monitoring — required (Catalina+) for the tap to actually
///    receive keyboard events; without it, tapCreate succeeds but no
///    events flow. This is the silent denial path that wedged us for hours.
///
/// The system has no notification for any grant flip; we poll on
/// `didBecomeActive` (cheap) AND run a short fast-poll burst right after a
/// permission prompt is triggered, so the moment the user flips the toggle
/// in System Settings the app notices without requiring a restart.
@MainActor
@Observable
final class PermissionsManager {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Permissions")

    enum MicrophoneStatus: Equatable {
        case undetermined
        case granted
        case denied
    }

    /// Injection point for the three permission probes. Production uses
    /// `.system` which calls AVCaptureDevice / AXIsProcessTrusted /
    /// IOHIDCheckAccess. Tests pass mock probes that return scripted
    /// values so the fast-poll loop and refresh-delta logic can be
    /// exercised without touching real system state.
    struct Probes {
        let microphone: @Sendable () -> MicrophoneStatus
        let accessibility: @Sendable () -> Bool
        let inputMonitoring: @Sendable () -> Bool

        static let system = Self(
            microphone: {
                switch AVCaptureDevice.authorizationStatus(for: .audio) {
                case .authorized: .granted
                case .denied, .restricted: .denied
                case .notDetermined: .undetermined
                @unknown default: .undetermined
                }
            },
            accessibility: { AXIsProcessTrusted() },
            inputMonitoring: {
                IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
            }
        )
    }

    private(set) var microphone: MicrophoneStatus = .undetermined
    private(set) var accessibilityTrusted: Bool = false
    private(set) var inputMonitoringGranted: Bool = false

    /// Fires whenever any of the tracked permissions transitions to granted.
    /// HotkeyManager subscribes so it can re-attempt CGEvent.tapCreate the
    /// instant Accessibility + Input Monitoring become available — no app
    /// restart required.
    var onPermissionGranted: (() -> Void)?

    /// Active fast-poll timer (250ms cadence, 30s max). Used right after a
    /// permission prompt to catch the grant flip without waiting for the
    /// user to refocus the app.
    @ObservationIgnored private var fastPollTimer: Timer?
    @ObservationIgnored private var fastPollDeadline: Date?
    @ObservationIgnored private let probes: Probes

    var allGranted: Bool {
        microphone == .granted && accessibilityTrusted && inputMonitoringGranted
    }

    /// True while a fast-poll burst is active. Exposed for tests; production
    /// callers shouldn't need to inspect this.
    var isFastPolling: Bool { fastPollTimer != nil }

    init(probes: Probes = .system) {
        self.probes = probes
        refresh()
    }

    /// Re-read all permission states from the system. Cheap; safe to call often.
    /// Fires `onPermissionGranted` if any toggle flipped to granted.
    func refresh() {
        let priorMic = microphone
        let priorAX = accessibilityTrusted
        let priorIM = inputMonitoringGranted

        microphone = probes.microphone()
        accessibilityTrusted = probes.accessibility()
        inputMonitoringGranted = probes.inputMonitoring()

        let micFlipped = priorMic != .granted && microphone == .granted
        let axFlipped = !priorAX && accessibilityTrusted
        let imFlipped = !priorIM && inputMonitoringGranted

        if axFlipped || imFlipped || micFlipped {
            Self.logger.info("permission flip: mic=\(micFlipped) ax=\(axFlipped) im=\(imFlipped)")
            onPermissionGranted?()
        }
    }

    /// Burst-poll for the next 30 seconds at 250ms intervals. Use right
    /// after surfacing a permission prompt or after the user requests
    /// Settings — catches the grant within a quarter-second so the UI can
    /// react immediately instead of waiting for the next didBecomeActive.
    /// Self-cancels once `allGranted` becomes true or the deadline expires.
    func startFastPolling() {
        fastPollTimer?.invalidate()
        fastPollDeadline = Date().addingTimeInterval(30)
        Self.logger.info("startFastPolling: 250ms x 30s")
        fastPollTimer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self else { return }
                self.refresh()
                if self.allGranted || (self.fastPollDeadline.map { Date() >= $0 } ?? true) {
                    self.stopFastPolling()
                }
            }
        }
    }

    func stopFastPolling() {
        fastPollTimer?.invalidate()
        fastPollTimer = nil
        fastPollDeadline = nil
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
        startFastPolling()
    }

    func openAccessibilitySettings() {
        openSystemSettings(pane: "Privacy_Accessibility")
        startFastPolling()
    }

    /// Open the Input Monitoring pane. Required (Catalina+) for CGEvent
    /// taps that listen to keyboard events; without it, the tap installs
    /// but receives zero events (the silent denial path).
    func openInputMonitoringSettings() {
        openSystemSettings(pane: "Privacy_ListenEvent")
        startFastPolling()
    }

    /// Trigger the system Input Monitoring prompt. Required so the user
    /// gets the standard macOS approval dialog the first time around.
    @discardableResult
    func requestInputMonitoring() -> Bool {
        let granted = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        refresh()
        return granted
    }

    private func openSystemSettings(pane: String) {
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else {
            return
        }
        NSWorkspace.shared.open(url)
    }
}
