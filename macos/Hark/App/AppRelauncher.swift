import AppKit
import Foundation
import OSLog

/// Relaunch Hark from inside itself. Used by the onboarding wizard's
/// "Restart Hark" affordance when macOS TCC state diverges from what
/// System Settings reports — a common post-update problem where the
/// permission toggle appears ON in Settings but `AXIsProcessTrusted()`
/// / `IOHIDCheckAccess()` still return false because the running
/// process is holding stale TCC state from before the binary was
/// replaced. A clean process picks up the current TCC state and
/// usually resolves the drift without needing the user to toggle off
/// and on again.
///
/// Implementation: spawn `/usr/bin/open -n <bundle>` (which launches a
/// new instance regardless of LSUIElement / multiple-instance rules),
/// then call `NSApp.terminate(nil)` on a short delay so the new
/// instance has time to begin launching before this one disappears.
enum AppRelauncher {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "Relauncher")

    /// Relaunch the running app. Intentionally non-throwing: if `open`
    /// fails or the bundle path can't be resolved, we log and fall back
    /// to a plain terminate — the user can re-launch from Finder. There
    /// is no useful recovery path beyond "tell the user."
    @MainActor
    static func relaunch() {
        let bundlePath = Bundle.main.bundlePath
        Self.logger.info("relaunch requested; bundlePath=\(bundlePath, privacy: .public)")

        let task = Process()
        task.launchPath = "/usr/bin/open"
        task.arguments = ["-n", bundlePath]

        do {
            try task.run()
        } catch {
            Self.logger.error("relaunch: open failed: \(error.localizedDescription, privacy: .public)")
            NSApp.terminate(nil)
            return
        }

        // Give `open` a moment to actually start the new instance
        // before we exit. 250ms is enough for `open` to dispatch the
        // launch request to launchd; the new process will be up before
        // the user notices.
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) {
            NSApp.terminate(nil)
        }
    }
}
