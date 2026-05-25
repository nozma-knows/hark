import {
  createSdkMcpServer,
  query,
  tool,
  type SDKMessage,
} from "@anthropic-ai/claude-agent-sdk";
import { renderHistoryPreamble } from "../conversation.ts";
import {
  buildToolRegistry,
  type ToolEntry,
} from "../dispatch/registry.ts";
import { consumeSdkStream } from "../sdkStream.ts";
import { buildSystemPrompt } from "./prompt.ts";
import type { AgentClient, AgentExecuteOpts, AgentRunResult } from "./types.ts";

/**
 * AgentClient backed by the Claude Agent SDK. Used when the user has
 * authenticated via subscription OAuth (`claude setup-token`) instead
 * of an API key. The same structured tool registry as MessagesClient
 * is exposed to the SDK via an in-process MCP server — so the LLM
 * picks `mcp__hark__openApp` for "open Linear" exactly the way
 * MessagesClient routes `openApp`.
 *
 * The SDK's built-in Bash tool is intentionally NOT in `allowedTools`:
 * the user's `~/.claude/settings.json` permission rules can silently
 * deny Bash and we hit the fake-success failure mode (model narrates
 * "Opened Linear" but nothing happened). Routing through our MCP tools
 * bypasses Claude Code's Bash permission layer entirely — our tools
 * call `runArgv` / `runBash` directly inside the sidecar process.
 *
 * `consumeSdkStream` still does success verification: if the model
 * narrates a result without any tool_use blocks, we surface a real
 * error instead of a fake success pill.
 */

const MCP_SERVER_NAME = "hark";

export interface SdkClientOpts {
  /** Path to the user's locally-installed `claude` CLI binary. */
  claudeBinary: string;
  /** Test seam — inject an alternate registry. */
  toolRegistry?: ToolEntry[];
}

export class SdkClient implements AgentClient {
  readonly kind = "sdk" as const;

  constructor(private readonly opts: SdkClientOpts) {}

  async executeCommand(
    transcript: string,
    runOpts: AgentExecuteOpts = {}
  ): Promise<AgentRunResult> {
    const registry = this.opts.toolRegistry ?? buildToolRegistry();
    const systemPrompt = await buildSystemPrompt(registry);
    const preamble = renderHistoryPreamble(runOpts.recentTurns ?? []);

    const mcpServer = createSdkMcpServer({
      name: MCP_SERVER_NAME,
      version: "1.0.0",
      tools: registry.map((entry) => buildSdkTool(entry)),
    });

    const allowedTools = registry.map((t) => `mcp__${MCP_SERVER_NAME}__${t.name}`);

    const stream = query({
      prompt: `${systemPrompt}\n\n${preamble}Voice command: ${transcript}`,
      options: {
        maxTurns: 6,
        allowedTools,
        mcpServers: { [MCP_SERVER_NAME]: mcpServer },
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

/**
 * Wrap a `ToolEntry` as an SDK MCP tool. Each Hark tool exposes a Zod
 * raw shape (`zodShape`) — exactly the input the SDK's `tool()` helper
 * expects — so the model sees the same structured input on the SDK
 * path as on the Messages API path. The handler hands the raw args
 * back to `entry.invoke`, which re-validates via the tool's own
 * `parseInput` before executing (defence in depth — same path as the
 * Messages API client).
 */
function buildSdkTool(entry: ToolEntry) {
  return tool(
    entry.name,
    entry.description,
    entry.zodShape,
    async (args) => {
      const result = await entry.invoke(args);
      return {
        content: [
          {
            type: "text" as const,
            text: result.succeeded
              ? result.summary
              : `${result.summary}${result.error ? `\nerror: ${result.error}` : ""}`,
          },
        ],
        isError: !result.succeeded,
      };
    }
  );
}
