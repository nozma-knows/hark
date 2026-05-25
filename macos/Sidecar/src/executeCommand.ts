import { z } from "zod";
import { defaultStore, type ConversationStore } from "./conversation.ts";
import {
  createAgentClient,
  detectAgentAuth,
  type AgentClient,
} from "./llm/index.ts";
import type { ClaudeUsage, SdkErrorCode } from "./sdkStream.ts";
import type { LlmErrorCode } from "./llm/toolLoop.ts";

/**
 * Voice command → macOS action. Always goes through the LLM with the
 * full structured tool registry: the model is the router. Previously
 * we ran a regex-first dispatcher pass that ate any phrase starting
 * with a known verb ("open …") before the LLM saw it — that gave
 * sub-100ms latency on the common path but failed on complex compound
 * commands the regex misread. The LLM does a much better job picking
 * the right structured tool (openApp vs openInChromeProfile vs
 * createJuggleTask) because it reads the whole sentence, and prompt
 * caching keeps Haiku 4.5 latency tight in the common case.
 *
 * Transport is picked by `detectAgentAuth`:
 *   - ANTHROPIC_API_KEY → MessagesClient (Haiku 4.5 + cache + tools).
 *   - subscription OAuth → SdkClient (Agent SDK with MCP-exposed tools).
 *   - neither → "no_auth" error result so the pill renders cleanly.
 *
 * The wire result keeps telemetry fields (`route`, `bashCommands`,
 * `llmTurns`) so post-incident triage can answer "which path ran?
 * what actually executed?" without tailing log files.
 */

export const ExecuteCommandParams = z.object({
  transcript: z.string().min(1),
});
export type ExecuteCommandParams = z.infer<typeof ExecuteCommandParams>;

export interface ExecuteCommandResult {
  summary: string;
  succeeded: boolean;
  /** Which transport produced this result. */
  route: "llm-messages" | "llm-sdk" | "no-auth";
  /** Every bash command the tools actually executed, in order. */
  bashCommands: string[];
  /** Assistant turns observed. */
  llmTurns: number;
  /** Total wall-clock for the whole command. */
  latencyMs: number;
  errorCode?: ExecuteCommandErrorCode | undefined;
  usage?: ClaudeUsage | undefined;
}

export type ExecuteCommandErrorCode = SdkErrorCode | LlmErrorCode | "no_auth";

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
 * Test seam — inject an alternate conversation store. Production
 * uses the module-level `defaultStore`. Tests pass a fresh store so
 * cases don't leak state into each other.
 */
export interface ExecuteCommandDeps {
  conversationStore?: ConversationStore;
}

export async function executeCommand(
  raw: unknown,
  deps: ExecuteCommandDeps = {}
): Promise<ExecuteCommandResult> {
  const start = Date.now();
  const { transcript } = ExecuteCommandParams.parse(raw);
  const store = deps.conversationStore ?? defaultStore;

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

  // Pull recent turns BEFORE the call so the model can resolve
  // pronouns / "now" / "also" against actual context.
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
    ...(r.errorCode ? { errorCode: r.errorCode } : {}),
    ...(r.usage ? { usage: r.usage } : {}),
  };
}
