import { describe, expect, test } from "bun:test";
import { consumeSdkStream } from "../sdkStream.ts";

/**
 * Tests for the SDK stream consumer. Pinning down the failure modes
 * that have actually bitten us — Mac #2's silent Bash denial is the
 * headline case. The shape of the messages mirrors what the Claude
 * Agent SDK emits in practice (see `node_modules/@anthropic-ai/
 * claude-agent-sdk/dist/*.d.ts` if you need to extend the fixtures).
 */

async function* iter<T>(items: T[]): AsyncIterable<T> {
  for (const item of items) yield item;
}

const assistantWithToolUse = (command: string) => ({
  type: "assistant",
  message: {
    content: [
      { type: "text", text: "Sure, I'll do that." },
      { type: "tool_use", name: "Bash", id: "t1", input: { command } },
    ],
  },
});

const assistantTextOnly = (text: string) => ({
  type: "assistant",
  message: { content: [{ type: "text", text }] },
});

const successResult = (text: string, usage?: Record<string, number>) => ({
  type: "result",
  subtype: "success",
  result: text,
  ...(usage ? { usage } : {}),
});

describe("consumeSdkStream", () => {
  test("happy path: tool_use present + success result → succeeded", async () => {
    const r = await consumeSdkStream(
      iter([
        assistantWithToolUse("open -a Linear"),
        successResult("Opened Linear", {
          input_tokens: 100,
          output_tokens: 20,
          cache_read_input_tokens: 0,
          cache_creation_input_tokens: 0,
        }),
      ])
    );

    expect(r.succeeded).toBe(true);
    expect(r.summary).toBe("Opened Linear");
    expect(r.bashCommands).toEqual(["open -a Linear"]);
    expect(r.llmTurns).toBe(1);
    expect(r.errorCode).toBeUndefined();
    expect(r.usage?.inputTokens).toBe(100);
    expect(r.usage?.outputTokens).toBe(20);
  });

  test("fake-success: zero tool_use but success result → overridden to failure", async () => {
    // This is the Mac #2 bug. Claude Code denied Bash via settings.json,
    // the assistant narrated as if it ran, the SDK emitted success.
    const r = await consumeSdkStream(
      iter([
        assistantTextOnly("I'll open Linear for you."),
        successResult("Opened Linear"),
      ])
    );

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("claude_code_denied_bash");
    expect(r.summary).toContain("settings.json");
    expect(r.bashCommands).toEqual([]);
    expect(r.llmTurns).toBe(1);
  });

  test("multiple tool_use blocks accumulate in bashCommands", async () => {
    const r = await consumeSdkStream(
      iter([
        assistantWithToolUse("open -a Music"),
        assistantWithToolUse(`osascript -e 'tell application "Music" to play'`),
        successResult("Started Music"),
      ])
    );

    expect(r.succeeded).toBe(true);
    expect(r.bashCommands).toEqual([
      "open -a Music",
      `osascript -e 'tell application "Music" to play'`,
    ]);
    expect(r.llmTurns).toBe(2);
  });

  test("error subtype → succeeded false with sdk_error", async () => {
    const r = await consumeSdkStream(
      iter([
        assistantWithToolUse("open -a NonExistentApp"),
        { type: "result", subtype: "error", error: "command not found" },
      ])
    );

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("sdk_error");
    expect(r.summary).toBe("command not found");
    expect(r.bashCommands).toEqual(["open -a NonExistentApp"]);
  });

  test("no result message → no_result error", async () => {
    const r = await consumeSdkStream(iter([assistantTextOnly("hmm")]));

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("no_result");
    expect(r.summary).toBe("Agent returned no summary");
  });

  test("non-Bash tool_use is ignored for verification", async () => {
    // If a future SDK version exposes Read/Grep and Claude calls those
    // instead of Bash, we should NOT count those toward our verification
    // — they don't change the user's machine state.
    const r = await consumeSdkStream(
      iter([
        {
          type: "assistant",
          message: {
            content: [
              { type: "tool_use", name: "Read", id: "t1", input: { path: "/etc/hosts" } },
            ],
          },
        },
        successResult("Read the file"),
      ])
    );

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("claude_code_denied_bash");
    expect(r.bashCommands).toEqual([]);
  });

  test("tool_use with empty command string is ignored", async () => {
    const r = await consumeSdkStream(
      iter([
        {
          type: "assistant",
          message: {
            content: [
              { type: "tool_use", name: "Bash", id: "t1", input: { command: "" } },
            ],
          },
        },
        successResult("Done"),
      ])
    );

    expect(r.succeeded).toBe(false);
    expect(r.errorCode).toBe("claude_code_denied_bash");
    expect(r.bashCommands).toEqual([]);
  });

  test("content blocks on root message (no .message wrapper) are also walked", async () => {
    // Older SDK versions emit `{type: 'assistant', content: [...]}` instead
    // of nesting under `message.content`. Cover both shapes.
    const r = await consumeSdkStream(
      iter([
        {
          type: "assistant",
          content: [
            { type: "tool_use", name: "Bash", id: "t1", input: { command: "pbpaste" } },
          ],
        },
        successResult("Pasted"),
      ])
    );

    expect(r.succeeded).toBe(true);
    expect(r.bashCommands).toEqual(["pbpaste"]);
  });

  test("missing usage gracefully yields undefined usage", async () => {
    const r = await consumeSdkStream(
      iter([assistantWithToolUse("open ."), successResult("Opened cwd")])
    );

    expect(r.succeeded).toBe(true);
    expect(r.usage).toBeUndefined();
  });
});
