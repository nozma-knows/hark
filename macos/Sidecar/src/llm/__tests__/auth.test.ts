import { describe, expect, test } from "bun:test";
import { detectAgentAuth } from "../index.ts";

/**
 * Auth precedence — the single behavior that has to stay in lockstep
 * with Swift's `ClaudeAuth.detectMethod`. Pinning it here so a future
 * change to either side gets caught immediately.
 */
describe("detectAgentAuth", () => {
  test("ANTHROPIC_API_KEY wins over everything", () => {
    const auth = detectAgentAuth({
      ANTHROPIC_API_KEY: "sk-test",
      CLAUDE_CODE_OAUTH_TOKEN: "oauth-test",
      HARK_CLAUDE_BINARY: "/opt/homebrew/bin/claude",
    });
    expect(auth?.kind).toBe("api-key");
    expect(auth).toEqual({ kind: "api-key", apiKey: "sk-test" });
  });

  test("api-key carries through HARK_MODEL when set", () => {
    const auth = detectAgentAuth({
      ANTHROPIC_API_KEY: "sk-test",
      HARK_MODEL: "claude-opus-4-7",
    });
    expect(auth).toEqual({
      kind: "api-key",
      apiKey: "sk-test",
      model: "claude-opus-4-7",
    });
  });

  test("CLAUDE_CODE_OAUTH_TOKEN + HARK_CLAUDE_BINARY → subscription", () => {
    const auth = detectAgentAuth({
      CLAUDE_CODE_OAUTH_TOKEN: "oauth-test",
      HARK_CLAUDE_BINARY: "/opt/homebrew/bin/claude",
    });
    expect(auth?.kind).toBe("subscription");
    if (auth?.kind === "subscription") {
      expect(auth.oauthToken).toBe("oauth-test");
      expect(auth.claudeBinary).toBe("/opt/homebrew/bin/claude");
    }
  });

  test("HARK_CLAUDE_BINARY alone → subscription with empty token (CLI reads ~/.claude/)", () => {
    const auth = detectAgentAuth({
      HARK_CLAUDE_BINARY: "/opt/homebrew/bin/claude",
    });
    expect(auth?.kind).toBe("subscription");
    if (auth?.kind === "subscription") {
      expect(auth.oauthToken).toBe("");
      expect(auth.claudeBinary).toBe("/opt/homebrew/bin/claude");
    }
  });

  test("empty-string api key is treated as absent", () => {
    expect(detectAgentAuth({ ANTHROPIC_API_KEY: "" })).toBeNull();
  });

  test("empty-string oauth token without binary is null", () => {
    expect(detectAgentAuth({ CLAUDE_CODE_OAUTH_TOKEN: "" })).toBeNull();
  });

  test("no env vars → null", () => {
    expect(detectAgentAuth({})).toBeNull();
  });
});
