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

  test("recentTurns are rendered into the user prompt", async () => {
    // Capture the request body so we can assert the preamble shows up.
    // Holder is a single-element array so TS doesn't narrow back to null
    // after the awaited fetch call returns. Read `captured[0]` once we
    // know the call happened.
    const captured: Array<{ messages?: Array<{ content: string }> }> = [];
    const fetchImpl = (async (_url: string, init: RequestInit) => {
      captured[0] = JSON.parse(init.body as string);
      const fixture = {
        id: "1",
        type: "message",
        role: "assistant",
        content: [
          { type: "tool_use", id: "t1", name: "bash", input: { command: "echo ok" } },
        ],
        stop_reason: "tool_use",
        usage: { input_tokens: 10, output_tokens: 5 },
      };
      const followup = {
        id: "2",
        type: "message",
        role: "assistant",
        content: [{ type: "text", text: "Done." }],
        stop_reason: "end_turn",
        usage: { input_tokens: 12, output_tokens: 4 },
      };
      // Hand back the first fixture, then the followup on the second call.
      // (Returning the same fixture every time would loop forever.)
      return new Response(
        JSON.stringify(callCount++ === 0 ? fixture : followup),
        { status: 200 }
      );
    }) as unknown as typeof fetch;
    let callCount = 0;

    const client = new MessagesClient({ apiKey: "k", fetchImpl });
    await client.executeCommand("now share that screenshot", {
      recentTurns: [
        { transcript: "take a screenshot", summary: "Saved to Desktop", recordedAt: 0 },
      ],
    });

    const userMessage = captured[0]?.messages?.[0]?.content ?? "";
    expect(userMessage).toContain("Recent voice commands");
    expect(userMessage).toContain('"take a screenshot" → Saved to Desktop');
    expect(userMessage).toContain("Voice command: now share that screenshot");
  });

  test("empty recentTurns leaves the prompt without a preamble", async () => {
    // Holder is a single-element array so TS doesn't narrow back to null
    // after the awaited fetch call returns. Read `captured[0]` once we
    // know the call happened.
    const captured: Array<{ messages?: Array<{ content: string }> }> = [];
    const fetchImpl = (async (_url: string, init: RequestInit) => {
      captured[0] = JSON.parse(init.body as string);
      return new Response(
        JSON.stringify({
          id: "1",
          type: "message",
          role: "assistant",
          content: [{ type: "text", text: "I'll do that." }],
          stop_reason: "end_turn",
          usage: { input_tokens: 10, output_tokens: 5 },
        }),
        { status: 200 }
      );
    }) as unknown as typeof fetch;

    const client = new MessagesClient({ apiKey: "k", fetchImpl });
    await client.executeCommand("open Linear");

    const userMessage = captured[0]?.messages?.[0]?.content ?? "";
    expect(userMessage.startsWith("Voice command:")).toBe(true);
    expect(userMessage).not.toContain("Recent voice commands");
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
    // Malformed input means the tool's parseInput threw — no bash
    // command actually ran, so bashCommands stays empty. The tool
    // call DID happen (toolUseCount > 0), so the runToolLoop's
    // no-tool-use guard is satisfied and succeeded falls out of
    // the second turn's text response.
    expect(r.bashCommands).toEqual([]);
    expect(r.succeeded).toBe(true);
  });
});
