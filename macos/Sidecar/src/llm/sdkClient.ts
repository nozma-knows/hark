import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { consumeSdkStream } from "../sdkStream.ts";
import { buildSystemPrompt } from "./prompt.ts";
import type { AgentClient, AgentRunResult } from "./types.ts";

/**
 * AgentClient backed by the Claude Agent SDK. Used when the user has
 * authenticated via subscription OAuth (`claude setup-token`) instead
 * of an API key. Slower than the Messages path and subject to the
 * user's local `~/.claude/settings.json` permission rules — but it's
 * the only way to use a Claude Pro/Max subscription, which the
 * Messages API doesn't accept.
 *
 * Brittleness is mitigated by `consumeSdkStream`, which verifies a
 * Bash tool_use actually fired before returning succeeded=true. The
 * fake-success failure mode (settings.json denied Bash, model
 * narrated as if it ran) surfaces as a real error pill instead.
 */

export interface SdkClientOpts {
  /** Path to the user's locally-installed `claude` CLI binary. */
  claudeBinary: string;
}

export class SdkClient implements AgentClient {
  readonly kind = "sdk" as const;

  constructor(private readonly opts: SdkClientOpts) {}

  async executeCommand(transcript: string): Promise<AgentRunResult> {
    const systemPrompt = await buildSystemPrompt();
    const stream = query({
      prompt: `${systemPrompt}\n\nVoice command: ${transcript}`,
      options: {
        maxTurns: 6,
        allowedTools: ["Bash"],
        pathToClaudeCodeExecutable: this.opts.claudeBinary,
      },
    }) as AsyncIterable<SDKMessage>;

    const r = await consumeSdkStream(stream);
    return {
      summary: r.summary,
      succeeded: r.succeeded,
      ...(r.errorCode ? { errorCode: r.errorCode } : {}),
      bashCommands: r.bashCommands,
      llmTurns: r.llmTurns,
      ...(r.usage ? { usage: r.usage } : {}),
    };
  }
}
