@testable import Hark
import XCTest

/// PermissionsManager owns:
///   - refresh-delta detection (which transitions fire onPermissionGranted)
///   - fast-poll timer lifecycle
///   - allGranted aggregation
///
/// All three are now testable thanks to the injectable `Probes` struct.
/// We never touch real system state in these tests.
@MainActor
final class PermissionsManagerTests: XCTestCase {
    // MARK: - allGranted aggregation

    func testAllGrantedRequiresAllThree() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)

        XCTAssertFalse(pm.allGranted)

        probes.mic = .granted
        pm.refresh()
        XCTAssertFalse(pm.allGranted, "mic alone is not enough")

        probes.ax = true
        pm.refresh()
        XCTAssertFalse(pm.allGranted, "+ ax still missing input monitoring")

        probes.im = true
        pm.refresh()
        XCTAssertTrue(pm.allGranted, "all three → granted")
    }

    func testInitialRefreshHydratesFromProbes() {
        let probes = MutableProbes(mic: .granted, ax: true, im: true)
        let pm = PermissionsManager(probes: probes.value)

        XCTAssertEqual(pm.microphone, .granted)
        XCTAssertTrue(pm.accessibilityTrusted)
        XCTAssertTrue(pm.inputMonitoringGranted)
    }

    // MARK: - Delta detection / callback firing

    func testGrantCallbackFiresOnAccessibilityFlip() {
        let probes = MutableProbes(mic: .granted, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        probes.ax = true
        pm.refresh()

        XCTAssertEqual(calls.value, 1)
    }

    func testGrantCallbackFiresOnInputMonitoringFlip() {
        let probes = MutableProbes(mic: .granted, ax: true, im: false)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        probes.im = true
        pm.refresh()

        XCTAssertEqual(calls.value, 1)
    }

    func testGrantCallbackFiresOnMicrophoneFlip() {
        let probes = MutableProbes(mic: .undetermined, ax: true, im: true)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        probes.mic = .granted
        pm.refresh()

        XCTAssertEqual(calls.value, 1)
    }

    func testGrantCallbackDoesNotFireOnNoChange() {
        let probes = MutableProbes(mic: .granted, ax: true, im: true)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        pm.refresh()
        pm.refresh()
        pm.refresh()

        XCTAssertEqual(calls.value, 0, "refresh with stable state must NOT re-fire")
    }

    func testGrantCallbackDoesNotFireOnDowngrade() {
        let probes = MutableProbes(mic: .granted, ax: true, im: true)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        // User revokes accessibility — callback should NOT fire (the
        // callback is only for grants, since revocation needs no
        // restoration logic in the consumer).
        probes.ax = false
        pm.refresh()

        XCTAssertEqual(calls.value, 0)
        XCTAssertFalse(pm.accessibilityTrusted)
    }

    func testGrantCallbackFiresOncePerFlip() {
        let probes = MutableProbes(mic: .granted, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        let calls = Box(0)
        pm.onPermissionGranted = { calls.value += 1 }

        // Flip ax up
        probes.ax = true
        pm.refresh()
        XCTAssertEqual(calls.value, 1)

        // Refresh again with no change
        pm.refresh()
        XCTAssertEqual(calls.value, 1, "no flip → no additional call")

        // Flip im up — separate event
        probes.im = true
        pm.refresh()
        XCTAssertEqual(calls.value, 2)
    }

    // MARK: - Fast-poll lifecycle

    func testStartFastPollingFlipsIsFastPollingFlag() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        XCTAssertFalse(pm.isFastPolling)

        pm.startFastPolling()

        XCTAssertTrue(pm.isFastPolling)
        pm.stopFastPolling()
    }

    func testStopFastPollingClearsFlag() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        pm.startFastPolling()
        XCTAssertTrue(pm.isFastPolling)

        pm.stopFastPolling()

        XCTAssertFalse(pm.isFastPolling)
    }

    func testStartFastPollingInvalidatesPriorTimer() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)

        pm.startFastPolling()
        XCTAssertTrue(pm.isFastPolling)
        // Second call replaces the timer cleanly (no leak, no crash).
        pm.startFastPolling()
        XCTAssertTrue(pm.isFastPolling)
        pm.stopFastPolling()
    }

    func testFastPollAutoStopsWhenAllGranted() async {
        // The timer fires every 250ms; when allGranted flips true, the
        // next tick stops the timer. We seed with granted from the start
        // so the FIRST tick (after Timer.scheduledTimer's initial delay)
        // sees allGranted and stops.
        let probes = MutableProbes(mic: .granted, ax: true, im: true)
        let pm = PermissionsManager(probes: probes.value)
        // The constructor already set everything to granted, so the timer
        // should stop on its first tick.
        pm.startFastPolling()

        // Wait up to ~1s for the timer to self-stop.
        for _ in 0..<10 {
            if !pm.isFastPolling { break }
            try? await Task.sleep(nanoseconds: 100_000_000) // 100ms
        }

        XCTAssertFalse(pm.isFastPolling, "fast-poll must self-stop once allGranted")
    }

    // MARK: - openSettings starts fast-poll

    func testOpenAccessibilitySettingsStartsFastPoll() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        XCTAssertFalse(pm.isFastPolling)

        pm.openAccessibilitySettings()

        XCTAssertTrue(pm.isFastPolling)
        pm.stopFastPolling()
    }

    func testOpenInputMonitoringSettingsStartsFastPoll() {
        let probes = MutableProbes(mic: .denied, ax: false, im: false)
        let pm = PermissionsManager(probes: probes.value)
        XCTAssertFalse(pm.isFastPolling)

        pm.openInputMonitoringSettings()

        XCTAssertTrue(pm.isFastPolling)
        pm.stopFastPolling()
    }
}

// MARK: - Mutable probe bag for tests

/// Lets a test mutate the values and pass `value` (a snapshot) to the
/// manager. Each call to `refresh()` on the manager will read the latest
/// values from this bag via the captured closures.
///
/// `@unchecked Sendable` because PermissionsManager's `Probes` closures
/// are `@Sendable` — and they need to capture this bag. We're safe
/// because all the tests are `@MainActor` (every call to refresh / mic =
/// / ax = serializes on main); concurrency comes only from the fast-poll
/// timer which also dispatches to main.
private final class MutableProbes: @unchecked Sendable {
    private let lock = NSLock()
    private var _mic: PermissionsManager.MicrophoneStatus
    private var _ax: Bool
    private var _im: Bool

    var mic: PermissionsManager.MicrophoneStatus {
        get { lock.lock()
            defer { lock.unlock() }
            return _mic
        }
        set { lock.lock()
            _mic = newValue
            lock.unlock()
        }
    }

    var ax: Bool {
        get { lock.lock()
            defer { lock.unlock() }
            return _ax
        }
        set { lock.lock()
            _ax = newValue
            lock.unlock()
        }
    }

    var im: Bool {
        get { lock.lock()
            defer { lock.unlock() }
            return _im
        }
        set { lock.lock()
            _im = newValue
            lock.unlock()
        }
    }

    init(mic: PermissionsManager.MicrophoneStatus, ax: Bool, im: Bool) {
        _mic = mic
        _ax = ax
        _im = im
    }

    var value: PermissionsManager.Probes {
        PermissionsManager.Probes(
            microphone: { [weak self] in self?.mic ?? .undetermined },
            accessibility: { [weak self] in self?.ax ?? false },
            inputMonitoring: { [weak self] in self?.im ?? false }
        )
    }
}

// `Box` is provided by OrchestratorTestSupport.swift.
