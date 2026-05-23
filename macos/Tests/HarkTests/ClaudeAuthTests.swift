@testable import Hark
import XCTest

/// `ClaudeAuth.detectMethod(env:claudeHomeExists:)` is the precedence
/// rule that decides whether the sidecar gets OAuth or API-key auth (or
/// neither). It's the entire surface of how Hark resolves Anthropic
/// credentials — Anthropic ToS forbids us from redistributing
/// subscription auth, so this gate is also the compliance boundary.
///
/// The pure-function shape makes it easy to exhaustively test every
/// precedence path without touching real environment variables or the
/// user's actual `~/.claude/` directory.
final class ClaudeAuthTests: XCTestCase {
    // MARK: - Precedence: OAuth in env wins over everything

    func testOAuthEnvWinsOverClaudeHome() {
        let result = ClaudeAuth.detectMethod(
            env: [
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth-abc123",
                "ANTHROPIC_API_KEY": "sk-anthropic-xyz"
            ],
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .subscription(source: .environment))
    }

    func testOAuthEnvWinsOverApiKey() {
        let result = ClaudeAuth.detectMethod(
            env: [
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth-abc123",
                "ANTHROPIC_API_KEY": "sk-anthropic-xyz"
            ],
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .subscription(source: .environment))
    }

    // MARK: - ~/.claude/ wins over API key

    func testClaudeHomeWinsOverApiKey() {
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": "sk-anthropic-xyz"],
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .subscription(source: .claudeHome))
    }

    // MARK: - API key falls back when no subscription

    func testApiKeyDetectedWhenNoSubscription() {
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": "sk-anthropic-xyz"],
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .apiKey(source: .environment))
    }

    // MARK: - No auth → .none

    func testNoneWhenNothingFound() {
        let result = ClaudeAuth.detectMethod(env: [:], claudeHomeExists: false)
        XCTAssertEqual(result, .none)
    }

    func testNoneWhenIrrelevantEnvVars() {
        let result = ClaudeAuth.detectMethod(
            env: ["PATH": "/usr/bin", "HOME": "/Users/test"],
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .none)
    }

    // MARK: - Empty strings treated as missing

    /// A stale `export CLAUDE_CODE_OAUTH_TOKEN=` in the user's shell rc
    /// produces an empty-string env var — that's NOT a real credential
    /// and the resolver must treat it as missing, NOT as a malformed
    /// subscription that would then bypass the API-key fallback.
    func testEmptyOAuthEnvTreatedAsMissing() {
        let result = ClaudeAuth.detectMethod(
            env: [
                "CLAUDE_CODE_OAUTH_TOKEN": "",
                "ANTHROPIC_API_KEY": "sk-anthropic-xyz"
            ],
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .apiKey(source: .environment))
    }

    func testEmptyApiKeyEnvTreatedAsMissing() {
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": ""],
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .none)
    }

    // MARK: - ClaudeAuthMethod helpers

    func testIsResolvedTrueForSubscription() {
        XCTAssertTrue(ClaudeAuthMethod.subscription(source: .environment).isResolved)
        XCTAssertTrue(ClaudeAuthMethod.subscription(source: .claudeHome).isResolved)
    }

    func testIsResolvedTrueForApiKey() {
        XCTAssertTrue(ClaudeAuthMethod.apiKey(source: .environment).isResolved)
    }

    func testIsResolvedFalseForNone() {
        XCTAssertFalse(ClaudeAuthMethod.none.isResolved)
    }

    func testShortLabels() {
        XCTAssertEqual(
            ClaudeAuthMethod.subscription(source: .environment).shortLabel,
            "Claude Code subscription"
        )
        XCTAssertEqual(
            ClaudeAuthMethod.apiKey(source: .environment).shortLabel,
            "ANTHROPIC_API_KEY"
        )
        XCTAssertEqual(ClaudeAuthMethod.none.shortLabel, "Not configured")
    }

    // MARK: - candidatePaths search order

    /// The `claude` CLI search order matters: Homebrew's prefix wins
    /// over /usr/local because Homebrew is the modern default on Apple
    /// Silicon, and within Homebrew we prefer the user-readable
    /// `~/.local/bin` shim only after the global paths to avoid picking
    /// up stale dev installs. Pin the order.
    func testCandidatePathsOrder() {
        let paths = ClaudeAuth.candidatePaths(home: "/Users/test")
        XCTAssertEqual(paths, [
            "/opt/homebrew/bin/claude",
            "/usr/local/bin/claude",
            "/Users/test/.local/bin/claude",
            "/Users/test/.claude/local/claude"
        ])
    }

    func testCandidatePathsExpandsEmptyHomeGracefully() {
        // If $HOME is empty (rare but possible in sandboxed contexts),
        // the candidates should still be valid path strings — just with
        // empty home segments. The executability check filters them out
        // downstream.
        let paths = ClaudeAuth.candidatePaths(home: "")
        XCTAssertEqual(paths.count, 4)
        XCTAssertTrue(paths.allSatisfy { $0.contains("claude") })
    }

    // MARK: - firstExecutable picks the right candidate

    func testFirstExecutableReturnsNilWhenNonePresent() {
        let result = ClaudeAuth.firstExecutable(
            candidates: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            isExecutable: { _ in false }
        )
        XCTAssertNil(result)
    }

    func testFirstExecutableReturnsFirstMatch() {
        // Both /opt/homebrew and /usr/local are executable — must return
        // the FIRST one (Homebrew wins, matching the production search
        // order for Apple Silicon machines).
        let result = ClaudeAuth.firstExecutable(
            candidates: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            isExecutable: { _ in true }
        )
        XCTAssertEqual(result, "/opt/homebrew/bin/claude")
    }

    func testFirstExecutableSkipsNonExecutable() {
        // Mimics "Homebrew claude was uninstalled but binary file
        // remains, isn't executable" — fall through to /usr/local.
        let result = ClaudeAuth.firstExecutable(
            candidates: ["/opt/homebrew/bin/claude", "/usr/local/bin/claude"],
            isExecutable: { path in path == "/usr/local/bin/claude" }
        )
        XCTAssertEqual(result, "/usr/local/bin/claude")
    }

    // MARK: - buildSidecarEnvironment

    /// HOME present in base env is preserved verbatim — we never overwrite
    /// a user-set HOME, even if our fallback is "more correct."
    func testBuildEnvPreservesExistingHome() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["HOME": "/Users/custom", "PATH": "/usr/bin"],
            fallbackHome: "/Users/fallback",
            claudeBinaryPath: nil
        )
        XCTAssertEqual(result["HOME"], "/Users/custom")
        XCTAssertEqual(result["PATH"], "/usr/bin")
    }

    /// HOME missing from base → fallback fills it in. Required so the
    /// sidecar can find `~/.claude/` for OAuth token lookup when the
    /// app is launched from a context that strips HOME (LaunchAgent).
    func testBuildEnvUsesFallbackHomeWhenMissing() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["PATH": "/usr/bin"],
            fallbackHome: "/Users/fallback",
            claudeBinaryPath: nil
        )
        XCTAssertEqual(result["HOME"], "/Users/fallback")
    }

    /// Both HOME missing AND no fallback → don't synthesize anything.
    /// The sidecar will fail downstream with a clearer error than a
    /// made-up path would produce.
    func testBuildEnvNoHomeNoFallbackLeavesHomeUnset() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["PATH": "/usr/bin"],
            fallbackHome: nil,
            claudeBinaryPath: nil
        )
        XCTAssertNil(result["HOME"])
    }

    /// `claude` binary path threads through to `HARK_CLAUDE_BINARY` —
    /// the env var the sidecar reads to bridge to the user's
    /// locally-installed CLI.
    func testBuildEnvInjectsClaudeBinaryPath() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: [:],
            fallbackHome: nil,
            claudeBinaryPath: "/opt/homebrew/bin/claude"
        )
        XCTAssertEqual(result["HARK_CLAUDE_BINARY"], "/opt/homebrew/bin/claude")
    }

    /// Nil claude binary path → no `HARK_CLAUDE_BINARY` env var. Sidecar
    /// will fall back to the SDK's built-in resolution, which surfaces
    /// a clearer "Native CLI binary not found" error.
    func testBuildEnvOmitsClaudeBinaryWhenNil() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: [:],
            fallbackHome: nil,
            claudeBinaryPath: nil
        )
        XCTAssertNil(result["HARK_CLAUDE_BINARY"])
    }

    /// All inputs together → all three concerns honored in one
    /// composition. The integration test for the env-building function.
    func testBuildEnvCombinesAllConcerns() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["PATH": "/usr/bin", "USER": "noah"],
            fallbackHome: "/Users/noah",
            claudeBinaryPath: "/opt/homebrew/bin/claude"
        )
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["USER"], "noah")
        XCTAssertEqual(result["HOME"], "/Users/noah")
        XCTAssertEqual(result["HARK_CLAUDE_BINARY"], "/opt/homebrew/bin/claude")
    }
}
