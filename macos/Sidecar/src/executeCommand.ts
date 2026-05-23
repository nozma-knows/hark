import { z } from "zod";
import { tryMatch } from "./dispatch/index.ts";
import {
  createAgentClient,
  detectAgentAuth,
  type AgentClient,
} from "./llm/index.ts";
import type { ClaudeUsage, SdkErrorCode } from "./sdkStream.ts";
import type { LlmErrorCode } from "./llm/toolLoop.ts";

/**
 * Voice command → macOS action. Two routes:
 *
 *   1. Dispatcher path — deterministic match on common voice command
 *      shapes ("open Linear", "take a screenshot", …). Sub-100ms, free,
 *      bypasses the LLM and the user's settings.json entirely. Ships
 *      ~90% of voice commands by hit rate.
 *
 *   2. LLM fallback — for anything dispatchers don't claim. Picks the
 *      Messages API client (Haiku 4.5 + prompt caching) when the user
 *      has an ANTHROPIC_API_KEY, or the Claude Agent SDK client when
 *      they only have subscription OAuth. Both run through verification
 *      (no fake-success pills) and surface a uniform result shape.
 *
 * The wire result includes telemetry fields so post-incident triage
 * can answer "which path ran?" / "did Bash actually fire?" without
 * tailing log files.
 */

export const ExecuteCommandParams = z.object({
  transcript: z.string().min(1),
});
export type ExecuteCommandParams = z.infer<typeof ExecuteCommandParams>;

export interface ExecuteCommandResult {
  summary: string;
  succeeded: boolean;
  /** Which code path produced this result. */
  route: "dispatcher" | "llm-messages" | "llm-sdk" | "no-auth";
  /** Stable id of the dispatcher that fired, when `route === "dispatcher"`. */
  dispatcherId?: string | undefined;
  /** Every Bash command actually executed, in order. */
  bashCommands: string[];
  /** Assistant turns observed (0 for the dispatcher path). */
  llmTurns: number;
  /** Total wall-clock for the whole command. */
  latencyMs: number;
  errorCode?: ExecuteCommandErrorCode | undefined;
  usage?: ClaudeUsage | undefined;
}

export type ExecuteCommandErrorCode =
  | SdkErrorCode
  | LlmErrorCode
  | "dispatcher_failed"
  | "no_auth";

/**
 * Cached agent client. Auth detection reads env, which is stable across
 * the sidecar's lifetime — no point re-detecting per request.
 */
let cachedClient: AgentClient | null = null;
let cachedClientKind: "missing" | "present" | null = null;

function getAgentClient(): AgentClient | null {
  if (cachedClientKind === "missing") return null;
  if (cachedClient !== null) return cachedClient;
  const auth = detectAgentAuth();
  if (auth === null) {
    cachedClientKind = "missing";
    return null;
  }
  cachedClient = createAgentClient(auth);
  cachedClientKind = "present";
  return cachedClient;
}

/** Test seam — reset the auth cache between cases. */
export function _resetAgentClientForTests(): void {
  cachedClient = null;
  cachedClientKind = null;
}

export async function executeCommand(raw: unknown): Promise<ExecuteCommandResult> {
  const start = Date.now();
  const { transcript } = ExecuteCommandParams.parse(raw);

  // 1. Dispatcher path.
  const matched = tryMatch(transcript);
  if (matched !== null) {
    const result = await matched.execute();
    return {
      summary: result.summary,
      succeeded: result.succeeded,
      route: "dispatcher",
      dispatcherId: matched.id,
      bashCommands: result.bashCommands,
      llmTurns: 0,
      latencyMs: Date.now() - start,
      ...(result.error ? { errorCode: "dispatcher_failed" as const } : {}),
    };
  }

  // 2. LLM fallback.
  const client = getAgentClient();
  if (client === null) {
    return {
      summary: "Hark isn't configured. Add an ANTHROPIC_API_KEY or run `claude setup-token` in Settings.",
      succeeded: false,
      route: "no-auth",
      bashCommands: [],
      llmTurns: 0,
      latencyMs: Date.now() - start,
      errorCode: "no_auth",
    };
  }

  const r = await client.executeCommand(transcript);
  return {
    summary: r.summary,
    succeeded: r.succeeded,
    route: client.kind === "messages" ? "llm-messages" : "llm-sdk",
    bashCommands: r.bashCommands,
    llmTurns: r.llmTurns,
    latencyMs: Date.now() - start,
    ...(r.errorCode ? { errorCode: r.errorCode } : {}),
    ...(r.usage ? { usage: r.usage } : {}),
  };
}
