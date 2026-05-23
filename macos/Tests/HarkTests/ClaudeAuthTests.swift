@testable import Hark
import XCTest

/// `ClaudeAuth.detectMethod(env:keychainApiKey:claudeHomeExists:)` is the
/// precedence rule that decides whether the sidecar gets API-key auth (the
/// fast Messages API path) or subscription OAuth (the SDK path), or
/// neither. Anthropic ToS forbids us from redistributing subscription
/// auth, so this gate is also the compliance boundary.
///
/// Precedence (highest first):
///   1. ANTHROPIC_API_KEY env  — explicit shell export wins
///   2. ANTHROPIC_API_KEY keychain  — user-entered via Settings
///   3. CLAUDE_CODE_OAUTH_TOKEN env  — subscription via env
///   4. ~/.claude/                — subscription via Claude Code CLI install
///
/// Why API key beats subscription: Messages API is faster (Haiku +
/// prompt caching) and bypasses Claude Code's settings.json permission
/// rules that have caused silent Bash denials. If the user explicitly
/// configured a key, they want the better path.
final class ClaudeAuthTests: XCTestCase {
    // MARK: - API key (env) wins over everything

    func testApiKeyEnvWinsOverOAuthEnv() {
        let result = ClaudeAuth.detectMethod(
            env: [
                "ANTHROPIC_API_KEY": "sk-anthropic-xyz",
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth-abc123",
            ],
            keychainApiKey: nil,
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .apiKey(source: .environment))
    }

    func testApiKeyEnvWinsOverClaudeHome() {
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": "sk-anthropic-xyz"],
            keychainApiKey: nil,
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .apiKey(source: .environment))
    }

    func testApiKeyEnvWinsOverKeychain() {
        // Shell-exported key takes precedence over the saved Keychain
        // value — matches the universal "explicit env beats persisted
        // config" rule users expect.
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": "sk-from-shell"],
            keychainApiKey: "sk-from-settings",
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .apiKey(source: .environment))
    }

    // MARK: - Keychain wins over subscription paths

    func testKeychainApiKeyWinsOverClaudeHome() {
        let result = ClaudeAuth.detectMethod(
            env: [:],
            keychainApiKey: "sk-from-settings",
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .apiKey(source: .keychain))
    }

    func testKeychainApiKeyWinsOverOAuthEnv() {
        let result = ClaudeAuth.detectMethod(
            env: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth"],
            keychainApiKey: "sk-from-settings",
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .apiKey(source: .keychain))
    }

    // MARK: - Subscription paths when no API key present

    func testOAuthEnvDetectedWhenNoApiKey() {
        let result = ClaudeAuth.detectMethod(
            env: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth"],
            keychainApiKey: nil,
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .subscription(source: .environment))
    }

    func testOAuthEnvWinsOverClaudeHome() {
        let result = ClaudeAuth.detectMethod(
            env: ["CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth"],
            keychainApiKey: nil,
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .subscription(source: .environment))
    }

    func testClaudeHomeDetectedWhenNoApiKeyNoOAuthEnv() {
        let result = ClaudeAuth.detectMethod(
            env: [:],
            keychainApiKey: nil,
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .subscription(source: .claudeHome))
    }

    // MARK: - No auth → .none

    func testNoneWhenNothingFound() {
        let result = ClaudeAuth.detectMethod(
            env: [:],
            keychainApiKey: nil,
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .none)
    }

    func testNoneWhenIrrelevantEnvVars() {
        let result = ClaudeAuth.detectMethod(
            env: ["PATH": "/usr/bin", "HOME": "/Users/test"],
            keychainApiKey: nil,
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .none)
    }

    // MARK: - Empty strings treated as missing

    /// A stale `export ANTHROPIC_API_KEY=` in the user's shell rc produces
    /// an empty-string env var. That's NOT a real credential — must fall
    /// through to the next-priority source, NOT short-circuit detection.
    func testEmptyApiKeyEnvFallsThroughToKeychain() {
        let result = ClaudeAuth.detectMethod(
            env: ["ANTHROPIC_API_KEY": ""],
            keychainApiKey: "sk-from-settings",
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .apiKey(source: .keychain))
    }

    func testEmptyApiKeyEnvFallsThroughToOAuth() {
        let result = ClaudeAuth.detectMethod(
            env: [
                "ANTHROPIC_API_KEY": "",
                "CLAUDE_CODE_OAUTH_TOKEN": "sk-oauth",
            ],
            keychainApiKey: nil,
            claudeHomeExists: false
        )
        XCTAssertEqual(result, .subscription(source: .environment))
    }

    func testEmptyOAuthEnvFallsThroughToClaudeHome() {
        let result = ClaudeAuth.detectMethod(
            env: ["CLAUDE_CODE_OAUTH_TOKEN": ""],
            keychainApiKey: nil,
            claudeHomeExists: true
        )
        XCTAssertEqual(result, .subscription(source: .claudeHome))
    }

    func testEmptyKeychainApiKeyTreatedAsAbsent() {
        let result = ClaudeAuth.detectMethod(
            env: [:],
            keychainApiKey: "",
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
        XCTAssertTrue(ClaudeAuthMethod.apiKey(source: .keychain).isResolved)
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

    /// Keychain-stored API key surfaces in the sidecar's env as
    /// `ANTHROPIC_API_KEY` so the TS-side `detectAgentAuth` picks the
    /// Messages API path. Without this, a key the user pasted into
    /// Settings would be invisible to the sidecar.
    func testBuildEnvInjectsKeychainApiKey() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: [:],
            fallbackHome: nil,
            claudeBinaryPath: nil,
            keychainApiKey: "sk-from-settings"
        )
        XCTAssertEqual(result["ANTHROPIC_API_KEY"], "sk-from-settings")
    }

    /// Explicit `ANTHROPIC_API_KEY` in the base env wins over a Keychain
    /// value. Mirrors the "shell export overrides persisted config" rule
    /// used everywhere else; also keeps tests + CI runs (which set env
    /// vars) deterministic regardless of what's saved in the keychain.
    func testBuildEnvKeychainDoesNotOverrideExistingApiKey() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["ANTHROPIC_API_KEY": "sk-from-shell"],
            fallbackHome: nil,
            claudeBinaryPath: nil,
            keychainApiKey: "sk-from-settings"
        )
        XCTAssertEqual(result["ANTHROPIC_API_KEY"], "sk-from-shell")
    }

    /// Empty Keychain key is treated as absent — don't pollute the
    /// sidecar's env with a misleading empty string.
    func testBuildEnvEmptyKeychainKeyIgnored() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: [:],
            fallbackHome: nil,
            claudeBinaryPath: nil,
            keychainApiKey: ""
        )
        XCTAssertNil(result["ANTHROPIC_API_KEY"])
    }

    /// All inputs together → all concerns honored in one composition.
    /// The integration test for the env-building function.
    func testBuildEnvCombinesAllConcerns() {
        let result = ClaudeAuth.buildSidecarEnvironment(
            base: ["PATH": "/usr/bin", "USER": "noah"],
            fallbackHome: "/Users/noah",
            claudeBinaryPath: "/opt/homebrew/bin/claude",
            keychainApiKey: "sk-from-settings"
        )
        XCTAssertEqual(result["PATH"], "/usr/bin")
        XCTAssertEqual(result["USER"], "noah")
        XCTAssertEqual(result["HOME"], "/Users/noah")
        XCTAssertEqual(result["HARK_CLAUDE_BINARY"], "/opt/homebrew/bin/claude")
        XCTAssertEqual(result["ANTHROPIC_API_KEY"], "sk-from-settings")
    }
}
