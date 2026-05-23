import { describe, expect, test } from "bun:test";
import { MessagesClient } from "../messagesClient.ts";
import type { MessagesResponse } from "../messagesApi.ts";

/**
 * End-to-end test of MessagesClient.executeCommand with a stub fetch.
 * This exercises the prompt builder, the tool loop, and the BashResult
 * formatting together — keeps the surface honest about what a real
 * voice command round-trip returns.
 *
 * The bash command we ask the stub model to run is `echo` so the
 * `runBash` call actually fires safely with no system side effects.
 */

describe("MessagesClient", () => {
  test("dispatches a Bash tool call and returns the model's summary", async () => {
    const fixtures: MessagesResponse[] = [
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "t1", name: "bash", input: { command: "echo hello" } },
        ],
        stop_reason: "tool_use",
        usage: { input_tokens: 50, output_tokens: 10 },
      },
      {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "Echoed hello." }],
        stop_reason: "end_turn",
        usage: { input_tokens: 60, output_tokens: 12 },
      },
    ];
    let i = 0;
    const fetchImpl = (async () => {
      const next = fixtures[i++];
      return new Response(JSON.stringify(next), {
        status: 200,
        headers: { "content-type": "application/json" },
      });
    }) as unknown as typeof fetch;

    const client = new MessagesClient({ apiKey: "k", fetchImpl });
    const r = await client.executeCommand("echo hello");

    expect(r.succeeded).toBe(true);
    expect(r.summary).toBe("Echoed hello.");
    expect(r.bashCommands).toEqual(["echo hello"]);
    expect(r.llmTurns).toBe(2);
    expect(r.usage?.inputTokens).toBe(110);
    expect(r.usage?.outputTokens).toBe(22);
  });

  test("surfaces fake-success as no_tool_use when the model never calls Bash", async () => {
    const fixture: MessagesResponse = {
      id: "1",
      type: "message",
      role: "assistant",
      content: [{ type: "text", text: "I would do that but I can't right now." }],
      stop_reason: "end_turn",
      usage: { input_tokens: 50, output_tokens: 12 },
    };
    const fetchImpl = (async () =>
      new Response(JSON.stringify(fixture), { status: 200 })) as unknown as typeof fetch;

    const client = new MessagesClient({ apiKey: "k", fetchImpl });
    const r = await client.executeCommand("do something impossible");

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("no_tool_use");
    expect(r.bashCommands).toEqual([]);
  });

  test("malformed tool_use input → reports isError back to the model", async () => {
    // First turn: model returns a tool_use with the wrong field.
    // Second turn: model recovers with a proper text summary.
    const fixtures: MessagesResponse[] = [
      {
        id: "1",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "t1", name: "bash", input: { foo: "bar" } },
        ],
        stop_reason: "tool_use",
        usage: { input_tokens: 50, output_tokens: 10 },
      },
      {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "Recovered." }],
        stop_reason: "end_turn",
        usage: { input_tokens: 60, output_tokens: 12 },
      },
    ];
    let i = 0;
    const fetchImpl = (async () => {
      const next = fixtures[i++];
      return new Response(JSON.stringify(next), { status: 200 });
    }) as unknown as typeof fetch;

    const client = new MessagesClient({ apiKey: "k", fetchImpl });
    const r = await client.executeCommand("anything");
    // The malformed input still counts as a tool_use attempt — the
    // tool result reports the error to the model but doesn't count
    // as a successful Bash invocation. Hence succeeded=true is
    // appropriate here only because the second turn produced text.
    expect(r.bashCommands).toEqual(["<invalid>"]);
    expect(r.succeeded).toBe(true);
  });
});
