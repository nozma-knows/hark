import { renderHistoryPreamble } from "../conversation.ts";
import {
  buildToolRegistry,
  findTool,
  type ToolEntry,
} from "../dispatch/registry.ts";
import { buildSystemPrompt } from "./prompt.ts";
import type { AgentClient, AgentExecuteOpts, AgentRunResult } from "./types.ts";
import { runToolLoop, type LlmRunOpts } from "./toolLoop.ts";

/**
 * AgentClient backed by the Anthropic Messages API directly. Used when
 * the user has supplied an `ANTHROPIC_API_KEY` — bypasses the local
 * `claude` binary entirely so the user's `~/.claude/settings.json`
 * permission rules can't silently deny our tool calls. Also faster:
 * Haiku 4.5 with prompt caching typically returns in under a second
 * for a single-tool voice command.
 *
 * Tool routing: we pass the full structured tool registry (openApp,
 * openUrl, search, …, plus the `bash` escape hatch) to the model.
 * The model is the router — picks `openApp` for "open Linear",
 * `openUrl` for "open github.com", and falls through to `bash` for
 * anything custom. No more regex pre-routing eating commands before
 * the LLM sees them.
 */

export interface MessagesClientOpts {
  apiKey: string;
  /** Override the default Haiku model — useful for testing or A/B. */
  model?: string;
  fetchImpl?: typeof fetch;
  /** Test seam for the retry wrapper. */
  retrySleep?: (ms: number) => Promise<void>;
  /** Test seam — inject an alternate registry (defaults to buildToolRegistry()). */
  toolRegistry?: ToolEntry[];
}

const DEFAULT_MODEL = "claude-haiku-4-5";

export class MessagesClient implements AgentClient {
  readonly kind = "messages" as const;

  constructor(private readonly opts: MessagesClientOpts) {}

  async executeCommand(
    transcript: string,
    runOpts: AgentExecuteOpts = {}
  ): Promise<AgentRunResult> {
    const registry = this.opts.toolRegistry ?? buildToolRegistry();
    const systemPrompt = await buildSystemPrompt(registry);
    const preamble = renderHistoryPreamble(runOpts.recentTurns ?? []);
    const toolDefinitions = registry.map((t) => ({
      name: t.name,
      description: t.description,
      input_schema: t.inputSchema,
    }));

    const bashCommands: string[] = [];

    const toolOpts: LlmRunOpts = {
      apiKey: this.opts.apiKey,
      model: this.opts.model ?? DEFAULT_MODEL,
      systemPrompt,
      userPrompt: `${preamble}Voice command: ${transcript}`,
      tools: toolDefinitions,
      onToolUse: async (block) => {
        const tool = findTool(registry, block.name);
        if (tool === null) {
          return {
            output: `Error: unknown tool "${block.name}"`,
            isError: true,
            rendered: `<unknown:${block.name}>`,
          };
        }
        const result = await tool.invoke(block.input);
        // Collect every bash command run by every tool — surfaced
        // upstairs for the "did anything actually run?" verification
        // and for the support-bundle telemetry.
        bashCommands.push(...result.bashCommands);
        return {
          output: formatToolResult(result),
          isError: !result.succeeded,
          rendered: result.bashCommands.join(" && ") || tool.name,
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
      bashCommands,
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
 * Render a tool result as the body of a `tool_result` content block.
 * Includes the human summary + any stderr so the model can recover
 * from failures by trying a different tool.
 */
function formatToolResult(r: {
  summary: string;
  succeeded: boolean;
  error?: string | undefined;
}): string {
  if (r.succeeded) return r.summary;
  return r.error ? `${r.summary}\nerror: ${r.error}` : r.summary;
}
