import AppKit
import Combine
import Foundation
import Observation
import OSLog
import Sparkle

/// Thin wrapper around `SPUStandardUpdaterController` so SwiftUI can observe
/// the "can check for updates" state and surface a "Check for Updates…"
/// menu item / button. Sparkle's own controller handles all the heavy
/// lifting (background scheduling, appcast fetch, signature verification,
/// install).
///
/// **Security gating.** With an empty `SUPublicEDKey`, Sparkle silently
/// disables EdDSA signature verification and would happily install any DMG
/// served at our feed URL — including an attacker's. This wrapper refuses
/// to enable automatic background checks unless the key is populated, AND
/// the explicit "Check for Updates…" menu item gracefully tells the user
/// the channel isn't ready instead of running an unsigned check.
///
/// Wiring requirements (verified by `hasValidSigningKey`):
///   - `SUFeedURL` in Info.plist points to a public appcast.xml
///   - `SUPublicEDKey` in Info.plist matches the private key `release.sh`
///     uses to sign every DMG's `sparkle:edSignature`
///   - The bundle is Developer ID-signed + notarized (Sparkle refuses to
///     install unsigned updates by default once the EdDSA key is present)
@MainActor
@Observable
final class UpdateManager: NSObject {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "UpdateManager")

    private let controller: SPUStandardUpdaterController

    /// True only when `SUPublicEDKey` is present AND non-empty in Info.plist.
    /// Drives whether automatic checks run and whether the menu item is live.
    let hasValidSigningKey: Bool

    /// Bound to the "Check for Updates…" menu item's `isEnabled`. Sparkle
    /// updates this as it transitions between idle and an in-flight check.
    /// When `hasValidSigningKey` is false, this stays false regardless of
    /// Sparkle's internal state — we won't run unverified update checks.
    private(set) var canCheckForUpdates: Bool = false

    override init() {
        hasValidSigningKey = Self.detectValidSigningKey()
        // Only auto-start the updater (which schedules background checks per
        // SUScheduledCheckInterval) when we have a signing key. Without one,
        // we instantiate the controller without starting it — keeps the
        // controller usable for manual checks if the user later configures
        // a key without relaunching, but no silent background traffic flows.
        controller = SPUStandardUpdaterController(
            startingUpdater: Self.detectValidSigningKey(),
            updaterDelegate: nil,
            userDriverDelegate: nil
        )
        super.init()

        if hasValidSigningKey {
            // Observe `canCheckForUpdates` so menu enable/disable matches
            // Sparkle's current state. KVO bridge; Sparkle exposes the
            // property as Objective-C KVO-observable.
            controller.updater.publisher(for: \.canCheckForUpdates)
                .receive(on: DispatchQueue.main)
                .sink { [weak self] value in
                    self?.canCheckForUpdates = value
                }
                .store(in: &cancellables)
            let feed = controller.updater.feedURL?.absoluteString ?? "<none>"
            Self.logger.info("Sparkle updater initialized (feed=\(feed, privacy: .public))")
            FileLogger.shared.log(.info, category: "UpdateManager", "auto-update enabled (feed=\(feed))")
        } else {
            Self.logger.warning("SUPublicEDKey missing — auto-update DISABLED for safety")
            FileLogger.shared.log(
                .warning,
                category: "UpdateManager",
                "auto-update disabled: SUPublicEDKey is empty in Info.plist"
            )
        }
    }

    /// Trigger a user-visible update check. Sparkle shows its own UI for
    /// "Checking…" / "Up to date" / "Update available" — we just hand off.
    /// No-op when no signing key is configured; the menu item is already
    /// disabled in that state so this guards against direct programmatic
    /// invocation only.
    func checkForUpdates() {
        guard hasValidSigningKey else {
            Self.logger.warning("checkForUpdates called but no signing key — refusing")
            return
        }
        controller.checkForUpdates(nil)
    }

    @ObservationIgnored private var cancellables: Set<AnyCancellable> = []

    /// Reads SUPublicEDKey from the active bundle's Info.plist. Returns true
    /// only when present and non-empty after trimming whitespace, since the
    /// XcodeGen template defaults to an empty string and we treat that as
    /// "not configured."
    private static func detectValidSigningKey() -> Bool {
        detectValidSigningKey(in: Bundle.main.infoDictionary)
    }

    /// Pure-function variant for tests — accepts the dictionary so the
    /// validation logic can be exercised against the four real failure
    /// modes (missing, empty, whitespace-only, populated) without touching
    /// `Bundle.main`. `nonisolated` so tests can call it from any context;
    /// `internal` (not `private`) for `@testable import`.
    nonisolated static func detectValidSigningKey(in info: [String: Any]?) -> Bool {
        guard let info else { return false }
        guard let raw = info["SUPublicEDKey"] as? String else { return false }
        return !raw.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
