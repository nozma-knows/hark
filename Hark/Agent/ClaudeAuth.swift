import Foundation
import Observation
import OSLog

/// What we found on the user's machine the sidecar can use to authenticate to Claude.
///
/// Hark never bundles, transmits, or stores Anthropic credentials — every install
/// brings its own auth. Anthropic's terms explicitly forbid third-party
/// redistribution of subscription auth, so this enum is the entirety of how
/// the sidecar gets credentialed: pass-through of values already on disk or in
/// the user's environment.
enum ClaudeAuthMethod: Equatable {
    /// User has run `claude setup-token`; an OAuth token is in the env or
    /// readable from `~/.claude/`. The sidecar inherits it via environment.
    case subscription(source: ClaudeAuthSource)

    /// User supplied their own `ANTHROPIC_API_KEY` (env var or Keychain).
    case apiKey(source: ClaudeAuthSource)

    /// Nothing usable found. Onboarding prompts.
    case none

    var isResolved: Bool {
        self != .none
    }

    var shortLabel: String {
        switch self {
        case .subscription: "Claude Code subscription"
        case .apiKey: "ANTHROPIC_API_KEY"
        case .none: "Not configured"
        }
    }
}

enum ClaudeAuthSource: String, Equatable {
    /// `CLAUDE_CODE_OAUTH_TOKEN` or `ANTHROPIC_API_KEY` present in Hark's env.
    case environment
    /// `~/.claude/` directory exists (Claude Code CLI keeps credentials here).
    case claudeHome = "~/.claude/"
}

@MainActor
@Observable
final class ClaudeAuth {
    private static let logger = Logger(subsystem: "co.milbo.hark", category: "ClaudeAuth")

    private(set) var method: ClaudeAuthMethod = .none

    /// Did we detect a `claude` CLI binary on PATH? Used by the onboarding to
    /// offer "Generate OAuth token" only when it's runnable.
    private(set) var claudeBinaryPath: String?

    init() {
        refresh()
    }

    /// Re-probe the environment + filesystem for usable auth. Cheap; safe to
    /// call from the onboarding poll or after a manual config change.
    func refresh() {
        let env = ProcessInfo.processInfo.environment
        claudeBinaryPath = Self.findClaudeBinary()

        // Priority: subscription OAuth in env > ~/.claude/ presence > API key in env
        if env["CLAUDE_CODE_OAUTH_TOKEN"]?.isEmpty == false {
            method = .subscription(source: .environment)
        } else if Self.claudeHomeExists() {
            method = .subscription(source: .claudeHome)
        } else if env["ANTHROPIC_API_KEY"]?.isEmpty == false {
            method = .apiKey(source: .environment)
        } else {
            method = .none
        }
        let described = String(describing: method)
        Self.logger.debug("Detected auth method: \(described, privacy: .public)")
    }

    /// Environment variables to inject into the sidecar `Process` so the
    /// Agent SDK can authenticate. Never logged in full.
    func sidecarEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        // Make sure HOME is propagated for Claude Code's ~/.claude lookup.
        if env["HOME"] == nil, let home = FileManager.default.urls(for: .userDirectory, in: .userDomainMask).first {
            env["HOME"] = home.path
        }
        return env
    }

    private static func claudeHomeExists() -> Bool {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return false }
        let dir = URL(fileURLWithPath: home).appending(path: ".claude", directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    private static func findClaudeBinary() -> String? {
        let candidates = [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/.local/bin/claude",
            "\(ProcessInfo.processInfo.environment["HOME"] ?? "")/.claude/local/claude"
        ]
        let fm = FileManager.default
        return candidates.first(where: { fm.isExecutableFile(atPath: $0) })
    }
}
