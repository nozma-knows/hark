import Foundation

/// Tiny persisted marker for "the user has reached the end of the
/// first-run wizard at least once." UserDefaults-backed so it survives
/// relaunches.
///
/// Onboarding completion is otherwise *derived* — the wizard only
/// re-appears while a required OS permission is missing
/// (`PermissionsManager.allGranted`), and nothing about Claude or the
/// Try-it step is persisted. That's deliberate for the permission gate,
/// but it means we can't tell "brand-new install, mid-setup" apart from
/// "finished the tour once, came back later." This flag draws that line.
///
/// Current consumer: the menu's "Connect Claude" nudge, which should
/// only appear *after* the user has finished onboarding (so we don't
/// double up on the in-wizard Claude step while setup is still live).
enum OnboardingProgress {
    private static let completedKey = "co.milbo.hark.onboardingCompleted"

    /// `true` once the user has walked through onboarding to the end at
    /// least once (finished or dismissed the final Try-it step).
    static var hasCompleted: Bool {
        UserDefaults.standard.bool(forKey: completedKey)
    }

    /// Record that the user reached the end of the wizard. Idempotent.
    static func markCompleted() {
        UserDefaults.standard.set(true, forKey: completedKey)
    }
}
