import { runBash } from "../runBash.ts";
import { buildSystemPrompt } from "./prompt.ts";
import type { AgentClient, AgentRunResult } from "./types.ts";
import { BASH_TOOL, type BashToolInput } from "./tools.ts";
import { runToolLoop, type LlmRunOpts } from "./toolLoop.ts";

/**
 * AgentClient backed by the Anthropic Messages API directly. Used when
 * the user has supplied an `ANTHROPIC_API_KEY` — bypasses the local
 * `claude` binary entirely so the user's `~/.claude/settings.json`
 * permission rules can't silently deny our Bash tool calls. Also
 * faster: Haiku 4.5 with prompt caching typically returns in under
 * a second for a single-tool voice command.
 */

export interface MessagesClientOpts {
  apiKey: string;
  /** Override the default Haiku model — useful for testing or A/B. */
  model?: string;
  fetchImpl?: typeof fetch;
  /** Test seam for the retry wrapper. */
  retrySleep?: (ms: number) => Promise<void>;
}

const DEFAULT_MODEL = "claude-haiku-4-5";

export class MessagesClient implements AgentClient {
  readonly kind = "messages" as const;

  constructor(private readonly opts: MessagesClientOpts) {}

  async executeCommand(transcript: string): Promise<AgentRunResult> {
    const systemPrompt = await buildSystemPrompt();
    const toolOpts: LlmRunOpts = {
      apiKey: this.opts.apiKey,
      model: this.opts.model ?? DEFAULT_MODEL,
      systemPrompt,
      userPrompt: `Voice command: ${transcript}`,
      tools: [BASH_TOOL],
      onToolUse: async (block) => {
        const input = block.input as Partial<BashToolInput>;
        if (typeof input.command !== "string" || input.command.length === 0) {
          return {
            output: "Error: missing or empty `command` field",
            isError: true,
            rendered: "<invalid>",
          };
        }
        const r = await runBash(input.command);
        return {
          output: formatBashResult(r),
          isError: r.exitCode !== 0 || r.timedOut,
          rendered: input.command,
        };
      },
      ...(this.opts.fetchImpl ? { fetchImpl: this.opts.fetchImpl } : {}),
      ...(this.opts.retrySleep ? { retrySleep: this.opts.retrySleep } : {}),
    };

    const result = await runToolLoop(toolOpts);

    return {
      summary: result.summary,
      succeeded: result.succeeded,
      ...(result.errorCode ? { errorCode: result.errorCode } : {}),
      bashCommands: result.bashCommands,
      llmTurns: result.llmTurns,
      usage: {
        inputTokens: result.usage.inputTokens,
        outputTokens: result.usage.outputTokens,
        cacheReadTokens: result.usage.cacheReadTokens,
        cacheCreationTokens: result.usage.cacheCreationTokens,
      },
    };
  }
}

/**
 * Format a bash result for inclusion in a `tool_result` block. We
 * concatenate stdout + stderr with a short header so the model sees
 * everything that mattered without us tokenizing it into structured
 * sub-fields the API doesn't natively understand.
 */
function formatBashResult(r: {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
}): string {
  const parts: string[] = [];
  if (r.timedOut) parts.push("[timed out]");
  parts.push(`exit ${r.exitCode}`);
  if (r.stdout.trim()) parts.push(`stdout:\n${r.stdout.trim()}`);
  if (r.stderr.trim()) parts.push(`stderr:\n${r.stderr.trim()}`);
  return parts.join("\n");
}
