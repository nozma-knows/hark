import type { ConversationTurn } from "../conversation.ts";
import type { ClaudeUsage, SdkErrorCode } from "../sdkStream.ts";
import type { LlmErrorCode } from "./toolLoop.ts";

/**
 * Uniform agent surface — `executeCommand.ts` calls one of these
 * without caring whether the underlying transport is the Anthropic
 * Messages API (api-key auth) or the Claude Agent SDK (subscription
 * OAuth auth). Both return the same `AgentRunResult` shape.
 *
 * Lives in its own file to break a circular dep — the concrete client
 * implementations need this type, and `index.ts` needs both — without
 * the split, `import type { AgentClient } from "./index.ts"` from a
 * client file would close the cycle.
 */

export interface AgentExecuteOpts {
  /**
   * Recent voice commands from this session, oldest first. Both clients
   * prepend a short rendering of these to the user prompt so the model
   * can resolve follow-ups like "now share that" against the actual
   * prior action. Empty array on first command of a session — clients
   * should suppress the preamble entirely in that case so the
   * prompt-cache hit rate stays high.
   */
  readonly recentTurns?: ReadonlyArray<ConversationTurn>;
}

export interface AgentClient {
  readonly kind: "messages" | "sdk";
  executeCommand(
    transcript: string,
    opts?: AgentExecuteOpts
  ): Promise<AgentRunResult>;
}

export interface AgentRunResult {
  summary: string;
  succeeded: boolean;
  errorCode?: LlmErrorCode | SdkErrorCode | undefined;
  bashCommands: string[];
  llmTurns: number;
  usage?: ClaudeUsage | undefined;
}

export type AgentAuth =
  | { kind: "api-key"; apiKey: string; model?: string }
  | { kind: "subscription"; oauthToken: string; claudeBinary: string };
