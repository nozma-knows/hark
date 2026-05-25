import { z } from "zod";
import { defaultStore, type ConversationStore } from "./conversation.ts";
import { tryMatch } from "./dispatch/index.ts";
import { isEscalatable, type DispatcherErrorCode } from "./dispatch/escalation.ts";
import {
  createAgentClient,
  detectAgentAuth,
  type AgentClient,
} from "./llm/index.ts";
import type { ClaudeUsage, SdkErrorCode } from "./sdkStream.ts";
import type { LlmErrorCode } from "./llm/toolLoop.ts";

/**
 * Voice command → macOS action. Three possible routes:
 *
 *   1. Dispatcher → success. Deterministic match on common voice
 *      command shapes ("open Linear", "take a screenshot", …). Sub-100ms,
 *      free, bypasses the LLM and the user's settings.json entirely.
 *      Ships ~90% of voice commands by hit rate.
 *
 *   2. Dispatcher → escalate → LLM. The dispatcher claimed the transcript
 *      (e.g., openApp matched "open Notes and take me to a new note")
 *      but the action couldn't actually be delivered (app doesn't exist
 *      with that compound name). Rather than surface a hard "isn't
 *      installed" error, we hand the original transcript to the LLM —
 *      which can interpret the multi-part intent correctly. See
 *      `dispatch/escalation.ts` for which error codes trigger this.
 *
 *   3. LLM fallback. Dispatcher didn't match at all. Picks the Messages
 *      API client (Haiku 4.5 + prompt caching) when the user has an
 *      ANTHROPIC_API_KEY, or the Claude Agent SDK client when they only
 *      have subscription OAuth.
 *
 * The wire result includes telemetry fields so post-incident triage
 * can answer "which path ran?" / "did we escalate?" / "did Bash actually
 * fire?" without tailing log files.
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
  /** Dispatcher id that tried first when this result came from the LLM
   *  fallback after an escalation. Surfaces in logs as "open-app →
   *  llm-messages" so a triager can see the dispatcher made an attempt
   *  before the LLM took over. */
  escalatedFrom?: string | undefined;
  /** Every Bash command actually executed, in order. When escalation
   *  happened, the dispatcher's attempted commands are NOT included
   *  (they didn't actually run, just tried). */
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
  | DispatcherErrorCode
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

/**
 * Test seams: tests can inject an alternate conversation store and/or
 * an explicit AgentClient instead of relying on the module-level
 * cache + the user's real env-based auth detection.
 */
export interface ExecuteCommandDeps {
  conversationStore?: ConversationStore;
  /** When set, used instead of the env-derived cached client. Lets the
   *  escalation integration test inject a stub LLM without touching
   *  ANTHROPIC_API_KEY or spawning a real sidecar process. */
  agentClient?: AgentClient;
}

export async function executeCommand(
  raw: unknown,
  deps: ExecuteCommandDeps = {}
): Promise<ExecuteCommandResult> {
  const start = Date.now();
  const { transcript } = ExecuteCommandParams.parse(raw);
  const store = deps.conversationStore ?? defaultStore;

  // 1. Dispatcher path. Dispatchers are intent-matched by regex; they
  //    don't need history to fire. We record their final outcome so a
  //    follow-up that lands on the LLM still sees the prior action.
  const matched = tryMatch(transcript);
  let escalatedFromDispatcherId: string | undefined;
  if (matched !== null) {
    const dispatched = await matched.execute();
    if (dispatched.succeeded || !isEscalatable(dispatched.errorCode)) {
      // Either the dispatcher succeeded, or its failure is non-recoverable
      // (real bash error, dispatcher_failed). Return as-is — Claude can't
      // do better with a "bash exit 1" than the dispatcher already did.
      store.record({ transcript, summary: dispatched.summary });
      return {
        summary: dispatched.summary,
        succeeded: dispatched.succeeded,
        route: "dispatcher",
        dispatcherId: matched.id,
        bashCommands: dispatched.bashCommands,
        llmTurns: 0,
        latencyMs: Date.now() - start,
        ...(dispatched.errorCode ? { errorCode: dispatched.errorCode } : {}),
      };
    }
    // Recoverable failure: dispatcher claimed greedily, target doesn't
    // exist on this machine. Fall through to the LLM with the original
    // transcript. Record the escalation in telemetry so logs show the
    // full journey (e.g., "open-app → llm-messages: Opened Notes and …").
    escalatedFromDispatcherId = matched.id;
  }

  // 2. LLM fallback — pull recent turns BEFORE the call so the model
  //    can resolve pronouns / "now" / "also" against actual context.
  const client = deps.agentClient ?? getAgentClient();
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

  const recentTurns = store.recentTurns();
  const r = await client.executeCommand(transcript, { recentTurns });
  // Record AFTER the call so the new turn isn't visible to itself
  // (would be self-referential context noise).
  store.record({ transcript, summary: r.summary });
  return {
    summary: r.summary,
    succeeded: r.succeeded,
    route: client.kind === "messages" ? "llm-messages" : "llm-sdk",
    bashCommands: r.bashCommands,
    llmTurns: r.llmTurns,
    latencyMs: Date.now() - start,
    ...(escalatedFromDispatcherId ? { escalatedFrom: escalatedFromDispatcherId } : {}),
    ...(r.errorCode ? { errorCode: r.errorCode } : {}),
    ...(r.usage ? { usage: r.usage } : {}),
  };
}
