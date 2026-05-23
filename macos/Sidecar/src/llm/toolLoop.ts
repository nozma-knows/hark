import {
  callMessages,
  type ContentBlock,
  type MessageParam,
  type MessagesApiOpts,
  type SystemBlock,
  type ToolDefinition,
  type ToolUseBlock,
} from "./messagesApi.ts";
import { withRetry } from "./retry.ts";

/**
 * Hand-rolled Messages API tool loop. Keeps the contract uniform with
 * the SDK path: returns the same `LlmRunSummary` shape, including
 * `tool_use` verification — `succeeded: false` when the model claimed
 * to do work but never actually called the tool.
 *
 * Why hand-rolled vs the @anthropic-ai/sdk's tool helper:
 *   - We need to count tool_use events for verification. The SDK
 *     hides this behind its iterator abstraction.
 *   - We want explicit control of caching markers + max_tokens.
 *   - The loop is small (~70 lines); maintenance cost is trivial.
 */

export interface LlmRunOpts {
  apiKey: string;
  model: string;
  systemPrompt: string;
  userPrompt: string;
  tools: ToolDefinition[];
  /** Caller runs each tool_use and returns a `tool_result` content string. */
  onToolUse: (block: ToolUseBlock) => Promise<{ output: string; isError: boolean; rendered: string }>;
  /** Cap turns so a confused model can't burn quota. */
  maxTurns?: number;
  /** Max output tokens per API call. */
  maxTokens?: number;
  /** Plumbed to `callMessages` for tests + per-call HTTP timeout. */
  fetchImpl?: typeof fetch;
  httpTimeoutMs?: number;
  /** Plumbed to `withRetry` for tests. */
  retrySleep?: (ms: number) => Promise<void>;
}

export interface LlmRunSummary {
  summary: string;
  succeeded: boolean;
  errorCode?: LlmErrorCode | undefined;
  bashCommands: string[];
  llmTurns: number;
  usage: AccumulatedUsage;
}

export type LlmErrorCode =
  | "no_tool_use"
  | "max_turns"
  | "empty_summary"
  | "api_error";

export interface AccumulatedUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

export async function runToolLoop(opts: LlmRunOpts): Promise<LlmRunSummary> {
  const maxTurns = opts.maxTurns ?? 4;
  const maxTokens = opts.maxTokens ?? 1024;

  // Mark the system prompt as cache-eligible. Anthropic's prompt cache
  // caches the entire prefix up to (and including) the last block with
  // cache_control set — so anchoring it here covers the system prompt
  // and the tool definitions, which is exactly what's identical
  // across every voice command on the same Mac.
  const system: SystemBlock[] = [
    { type: "text", text: opts.systemPrompt, cache_control: { type: "ephemeral" } },
  ];

  const messages: MessageParam[] = [
    { role: "user", content: opts.userPrompt },
  ];

  const usage: AccumulatedUsage = {
    inputTokens: 0, outputTokens: 0, cacheReadTokens: 0, cacheCreationTokens: 0,
  };
  const bashCommands: string[] = [];
  let turns = 0;
  let lastText = "";
  let toolUseCount = 0;

  const apiOpts: MessagesApiOpts = {
    apiKey: opts.apiKey,
    ...(opts.fetchImpl ? { fetchImpl: opts.fetchImpl } : {}),
    ...(opts.httpTimeoutMs !== undefined ? { timeoutMs: opts.httpTimeoutMs } : {}),
  };

  while (turns < maxTurns) {
    turns++;
    let response;
    try {
      response = await withRetry(
        () =>
          callMessages(
            { model: opts.model, max_tokens: maxTokens, system, messages, tools: opts.tools },
            apiOpts
          ),
        opts.retrySleep ? { sleep: opts.retrySleep } : {}
      );
    } catch (err) {
      const message =
        err instanceof Error
          ? err.message
          : typeof err === "object" && err !== null && "message" in err
            ? String((err as { message: unknown }).message)
            : "Anthropic API error";
      return {
        summary: "Couldn't reach Claude — try again.",
        succeeded: false,
        errorCode: "api_error",
        bashCommands,
        llmTurns: turns,
        usage,
      };
    }

    accumulateUsage(usage, response.usage);

    // Capture any text the model produced this turn — used as the
    // final pill summary if this is the last turn.
    const text = response.content
      .filter((b): b is { type: "text"; text: string } => b.type === "text")
      .map((b) => b.text)
      .join("");
    if (text) lastText = text;

    const toolUses = response.content.filter(
      (b): b is ToolUseBlock => b.type === "tool_use"
    );

    if (toolUses.length === 0) {
      // Model is done. Verify it actually executed a tool — without
      // this, an apologetic "I tried to open Linear but couldn't"
      // would surface as succeeded=true with zero side effects, the
      // same failure mode the SDK path's verification catches.
      if (toolUseCount === 0) {
        return {
          summary: lastText.trim() || "Couldn't run the command — try simpler phrasing.",
          succeeded: false,
          errorCode: "no_tool_use",
          bashCommands,
          llmTurns: turns,
          usage,
        };
      }
      return {
        summary: lastText.trim() || "Done",
        succeeded: true,
        bashCommands,
        llmTurns: turns,
        usage,
      };
    }

    // Run each tool_use, build matching tool_result blocks.
    const toolResults: ContentBlock[] = [];
    for (const use of toolUses) {
      toolUseCount++;
      const r = await opts.onToolUse(use);
      bashCommands.push(r.rendered);
      toolResults.push({
        type: "tool_result",
        tool_use_id: use.id,
        content: r.output,
        ...(r.isError ? { is_error: true } : {}),
      });
    }

    messages.push({ role: "assistant", content: response.content });
    messages.push({ role: "user", content: toolResults });
  }

  // Bailed out of the loop without ever getting a stop_reason of
  // "end_turn" — model is in a tight tool-use loop.
  return {
    summary: lastText.trim() || "Command took too long.",
    succeeded: false,
    errorCode: "max_turns",
    bashCommands,
    llmTurns: turns,
    usage,
  };
}

function accumulateUsage(acc: AccumulatedUsage, u: {
  input_tokens: number;
  output_tokens: number;
  cache_read_input_tokens?: number;
  cache_creation_input_tokens?: number;
}): void {
  acc.inputTokens += u.input_tokens ?? 0;
  acc.outputTokens += u.output_tokens ?? 0;
  acc.cacheReadTokens += u.cache_read_input_tokens ?? 0;
  acc.cacheCreationTokens += u.cache_creation_input_tokens ?? 0;
}
