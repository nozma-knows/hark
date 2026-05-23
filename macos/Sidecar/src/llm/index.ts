import { MessagesClient } from "./messagesClient.ts";
import { SdkClient } from "./sdkClient.ts";
import type { AgentAuth, AgentClient } from "./types.ts";

/**
 * Public surface for the LLM layer — auth detection, the factory that
 * picks the right transport, and re-exports of the underlying clients.
 *
 * The `AgentClient` interface itself lives in `./types.ts` so the two
 * concrete implementations can import it without closing a cycle.
 */

/**
 * Resolve the auth to use from the sidecar's environment. Mirrors the
 * Swift-side `ClaudeAuth.detectMethod` precedence so the two stay in
 * lockstep — both pick api-key over subscription when both are present.
 *
 *   1. ANTHROPIC_API_KEY  → Messages API (fastest, no settings.json)
 *   2. CLAUDE_CODE_OAUTH_TOKEN + HARK_CLAUDE_BINARY  → SDK
 *   3. HARK_CLAUDE_BINARY alone → SDK (token lives in ~/.claude/)
 *   4. nothing            → null (caller renders a config error)
 */
export function detectAgentAuth(
  env: Record<string, string | undefined> = process.env
): AgentAuth | null {
  const apiKey = env.ANTHROPIC_API_KEY;
  if (apiKey && apiKey.length > 0) {
    const model = env.HARK_MODEL;
    return model
      ? { kind: "api-key", apiKey, model }
      : { kind: "api-key", apiKey };
  }
  const oauth = env.CLAUDE_CODE_OAUTH_TOKEN;
  const binary = env.HARK_CLAUDE_BINARY;
  if (oauth && oauth.length > 0 && binary && binary.length > 0) {
    return { kind: "subscription", oauthToken: oauth, claudeBinary: binary };
  }
  // Subscription auth can also live in ~/.claude/ (detected on the Swift
  // side, which sets nothing in env). Treat presence of HARK_CLAUDE_BINARY
  // alone as enough — the SDK will pull the token from ~/.claude/ via the
  // claude binary itself.
  if (binary && binary.length > 0) {
    return { kind: "subscription", oauthToken: "", claudeBinary: binary };
  }
  return null;
}

/**
 * Factory: pick the right transport for the detected auth. Production
 * code calls `detectAgentAuth()` then `createAgentClient()`; tests can
 * construct either client directly to avoid env coupling.
 */
export function createAgentClient(auth: AgentAuth): AgentClient {
  switch (auth.kind) {
    case "api-key":
      return new MessagesClient(
        auth.model
          ? { apiKey: auth.apiKey, model: auth.model }
          : { apiKey: auth.apiKey }
      );
    case "subscription":
      return new SdkClient({ claudeBinary: auth.claudeBinary });
  }
}

export { MessagesClient } from "./messagesClient.ts";
export { SdkClient } from "./sdkClient.ts";
export type { AgentAuth, AgentClient, AgentRunResult } from "./types.ts";
