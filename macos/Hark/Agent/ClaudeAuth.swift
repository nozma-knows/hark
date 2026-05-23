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
        method = Self.detectMethod(env: env, claudeHomeExists: Self.claudeHomeExists())
        let described = String(describing: method)
        Self.logger.debug("Detected auth method: \(described, privacy: .public)")
    }

    /// Pure-function detection — exposed for tests so the precedence rules
    /// (OAuth env > ~/.claude/ > API key env) can be pinned down without
    /// touching real process state. `internal` (not `private`) for
    /// `@testable import`.
    nonisolated static func detectMethod(
        env: [String: String],
        claudeHomeExists: Bool
    )
        -> ClaudeAuthMethod
    {
        // Priority: subscription OAuth in env > ~/.claude/ presence > API key in env
        if env["CLAUDE_CODE_OAUTH_TOKEN"]?.isEmpty == false {
            return .subscription(source: .environment)
        }
        if claudeHomeExists {
            return .subscription(source: .claudeHome)
        }
        if env["ANTHROPIC_API_KEY"]?.isEmpty == false {
            return .apiKey(source: .environment)
        }
        return .none
    }

    /// Environment variables to inject into the sidecar `Process` so the
    /// Agent SDK can authenticate. Never logged in full.
    func sidecarEnvironment() -> [String: String] {
        Self.buildSidecarEnvironment(
            base: ProcessInfo.processInfo.environment,
            fallbackHome: FileManager.default.urls(for: .userDirectory, in: .userDomainMask).first?.path,
            claudeBinaryPath: claudeBinaryPath
        )
    }

    /// Pure-function variant for tests. Composes the sidecar environment
    /// dictionary from a base env + optional fallback HOME + optional
    /// claude binary path, without touching `ProcessInfo` or `FileManager`.
    nonisolated static func buildSidecarEnvironment(
        base: [String: String],
        fallbackHome: String?,
        claudeBinaryPath: String?
    )
        -> [String: String]
    {
        var env = base
        // Make sure HOME is propagated for Claude Code's ~/.claude lookup.
        // Don't OVERWRITE an existing HOME — users with custom shells may
        // have set it deliberately.
        if env["HOME"] == nil, let fallbackHome {
            env["HOME"] = fallbackHome
        }
        // The Agent SDK ships an optional ~200 MB native `claude` binary that
        // `bun build --compile` doesn't include in our single-binary build.
        // Surfacing the user's locally-installed `claude` here lets the
        // sidecar pass it as `pathToClaudeCodeExecutable` to the SDK,
        // avoiding the "Native CLI binary for darwin-arm64 not found" error.
        if let path = claudeBinaryPath {
            env["HARK_CLAUDE_BINARY"] = path
        }
        return env
    }

    private static func claudeHomeExists() -> Bool {
        guard let home = ProcessInfo.processInfo.environment["HOME"] else { return false }
        let dir = URL(fileURLWithPath: home).appending(path: ".claude", directoryHint: .isDirectory)
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: dir.path, isDirectory: &isDir) && isDir.boolValue
    }

    /// Open Terminal.app and run `claude setup-token` against the detected
    /// CLI path. AppleScript-driven so the user can react to the interactive
    /// browser flow that follows.
    func runSetupToken() {
        guard let path = claudeBinaryPath else { return }
        let source = """
        tell application "Terminal"
            activate
            do script "\(path) setup-token"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: source)?.executeAndReturnError(&error)
    }

    private static func findClaudeBinary() -> String? {
        let home = ProcessInfo.processInfo.environment["HOME"] ?? ""
        return firstExecutable(
            candidates: candidatePaths(home: home),
            isExecutable: FileManager.default.isExecutableFile(atPath:)
        )
    }

    /// Canonical search order for the `claude` CLI binary. `internal`
    /// so tests can pin down the order — moving Homebrew's prefix
    /// earlier or later changes which install of `claude` wins on
    /// machines that have several.
    nonisolated static func candidatePaths(home: String) -> [String] {
        [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "\(home)/.local/bin/claude",
            "\(home)/.claude/local/claude"
        ]
    }

    /// First candidate path that passes the executability check, or nil
    /// if none does. Pure function — tests inject a closure to simulate
    /// "only /usr/local/bin/claude is executable" etc. without touching
    /// the real filesystem.
    nonisolated static func firstExecutable(
        candidates: [String],
        isExecutable: (String) -> Bool
    )
        -> String?
    {
        candidates.first(where: isExecutable)
    }
}
