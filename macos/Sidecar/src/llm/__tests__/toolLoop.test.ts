import { describe, expect, test } from "bun:test";
import type { MessagesResponse } from "../messagesApi.ts";
import { runToolLoop } from "../toolLoop.ts";

/**
 * The tool-loop verification mirrors what `consumeSdkStream` does for
 * the SDK path: refuse to claim success when zero tool calls fired.
 * These tests cover the loop's branches with a fetch-mock that hands
 * back canned MessagesResponse fixtures in sequence.
 */

const BASH_TOOL = {
  name: "bash",
  description: "run",
  input_schema: { type: "object", properties: { command: { type: "string" } }, required: ["command"] },
};

function makeFetchMock(responses: MessagesResponse[]): typeof fetch {
  let i = 0;
  const impl = async () => {
    const next = responses[i++];
    if (!next) throw new Error(`fetchMock: out of responses after ${i - 1} calls`);
    return new Response(JSON.stringify(next), {
      status: 200,
      headers: { "content-type": "application/json" },
    });
  };
  return impl as unknown as typeof fetch;
}

const usage = (extra: Partial<MessagesResponse["usage"]> = {}) => ({
  input_tokens: 50,
  output_tokens: 10,
  cache_read_input_tokens: 0,
  cache_creation_input_tokens: 0,
  ...extra,
});

describe("runToolLoop", () => {
  test("happy path: tool_use → tool_result → text → succeeded", async () => {
    const fetchImpl = makeFetchMock([
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "t1", name: "bash", input: { command: "open -a Linear" } },
        ],
        stop_reason: "tool_use",
        usage: usage(),
      },
      {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "Opened Linear." }],
        stop_reason: "end_turn",
        usage: usage(),
      },
    ]);

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: Open Linear",
      tools: [BASH_TOOL],
      fetchImpl,
      onToolUse: async (block) => ({
        output: "exit 0",
        isError: false,
        rendered: (block.input as { command: string }).command,
      }),
    });

    expect(r.succeeded).toBe(true);
    expect(r.summary).toBe("Opened Linear.");
    expect(r.bashCommands).toEqual(["open -a Linear"]);
    expect(r.llmTurns).toBe(2);
    expect(r.usage.inputTokens).toBe(100);
    expect(r.usage.outputTokens).toBe(20);
    expect(r.errorCode).toBeUndefined();
  });

  test("zero tool_use → no_tool_use error (fake-success caught)", async () => {
    const fetchImpl = makeFetchMock([
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "I'll open Linear for you." }],
        stop_reason: "end_turn",
        usage: usage(),
      },
    ]);

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: Open Linear",
      tools: [BASH_TOOL],
      fetchImpl,
      onToolUse: async () => ({ output: "", isError: false, rendered: "" }),
    });

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("no_tool_use");
    expect(r.bashCommands).toEqual([]);
  });

  test("max_turns: model never stops calling tools → max_turns error", async () => {
    // Three turns of pure tool_use responses, no end_turn — should bail
    // after maxTurns and report max_turns.
    const turn = (): MessagesResponse => ({
      id: "x",
      type: "message",
      role: "assistant",
      content: [
        { type: "tool_use", id: "t", name: "bash", input: { command: "echo loop" } },
      ],
      stop_reason: "tool_use",
      usage: usage(),
    });
    const fetchImpl = makeFetchMock([turn(), turn(), turn()]);

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: loop forever",
      tools: [BASH_TOOL],
      fetchImpl,
      maxTurns: 3,
      onToolUse: async () => ({ output: "ok", isError: false, rendered: "echo loop" }),
    });

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("max_turns");
    expect(r.bashCommands).toEqual(["echo loop", "echo loop", "echo loop"]);
    expect(r.llmTurns).toBe(3);
  });

  test("API error short-circuits with api_error", async () => {
    const errorFetch = (async () => {
      throw { transient: false, status: 401, message: "401 Unauthorized" };
    }) as unknown as typeof fetch;

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: anything",
      tools: [BASH_TOOL],
      fetchImpl: errorFetch,
      retrySleep: async () => {},
      onToolUse: async () => ({ output: "", isError: false, rendered: "" }),
    });

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("api_error");
  });

  test("multiple tool_use blocks in one turn all execute", async () => {
    const fetchImpl = makeFetchMock([
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "a", name: "bash", input: { command: "open -a Music" } },
          { type: "tool_use", id: "b", name: "bash", input: { command: "osascript -e 'tell application \"Music\" to play'" } },
        ],
        stop_reason: "tool_use",
        usage: usage(),
      },
      {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "Started music." }],
        stop_reason: "end_turn",
        usage: usage(),
      },
    ]);

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: play music",
      tools: [BASH_TOOL],
      fetchImpl,
      onToolUse: async (block) => ({
        output: "exit 0",
        isError: false,
        rendered: (block.input as { command: string }).command,
      }),
    });

    expect(r.succeeded).toBe(true);
    expect(r.bashCommands).toHaveLength(2);
  });

  test("accumulates cache tokens across turns", async () => {
    const fetchImpl = makeFetchMock([
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [{ type: "tool_use", id: "t1", name: "bash", input: { command: "echo a" } }],
        stop_reason: "tool_use",
        usage: usage({ cache_creation_input_tokens: 1500 }),
      },
      {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "ok" }],
        stop_reason: "end_turn",
        usage: usage({ cache_read_input_tokens: 1500 }),
      },
    ]);

    const r = await runToolLoop({
      apiKey: "k",
      model: "test",
      systemPrompt: "sys",
      userPrompt: "Voice command: anything",
      tools: [BASH_TOOL],
      fetchImpl,
      onToolUse: async () => ({ output: "exit 0", isError: false, rendered: "echo a" }),
    });

    expect(r.usage.cacheReadTokens).toBe(1500);
    expect(r.usage.cacheCreationTokens).toBe(1500);
  });
});
