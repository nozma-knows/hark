import { defaultStore } from "./conversation.ts";
import { executeCommand } from "./executeCommand.ts";
import { polishTranscript } from "./polishTranscript.ts";
import { err, ok, RequestSchema, type Response } from "./protocol.ts";

/**
 * One handler per `request.method`. Handlers receive the deserialized
 * `params` (or undefined) and return either a JSON-serializable result or
 * throw — thrown errors are converted into an error response by the loop.
 */
type Handler = (params: unknown) => Promise<unknown>;

const handlers: Record<string, Handler> = {
  // Connectivity check: Swift sends ping; we return when we got it and what
  // we received so the round-trip latency is measurable from the caller.
  ping: async (params) => ({
    pong: Date.now(),
    echoed: params ?? null,
  }),

  // Clean a raw Whisper transcript via Claude — punctuation, casing, fillers.
  // Falls back to the raw input on any internal failure (handler-level
  // throws are caught by the dispatch loop and surfaced as JSON errors).
  polishTranscript: async (params) => polishTranscript(params),

  // Voice command → macOS action. Claude drives Bash to fulfill the user's
  // spoken request (open apps, run AppleScript, run Shortcuts, etc.).
  executeCommand: async (params) => executeCommand(params),

  // Clear the in-memory rolling history of recent voice commands. Useful
  // when the user wants to start a fresh "topic" mid-session without
  // waiting for the 5-minute TTL to drop the buffer. No params, no
  // payload — just a fire-and-forget acknowledgment.
  resetConversation: async () => {
    defaultStore.clear();
    return { cleared: true };
  },
};

const decoder = new TextDecoder();
let buffer = "";

const writeLine = (line: string): void => {
  process.stdout.write(line + "\n");
};

const send = (response: Response): void => {
  writeLine(JSON.stringify(response));
};

const handleLine = async (line: string): Promise<void> => {
  let json: unknown;
  try {
    json = JSON.parse(line);
  } catch {
    return; // Skip malformed lines; the spec is one valid JSON per line.
  }
  const parsed = RequestSchema.safeParse(json);
  if (!parsed.success) {
    return; // Non-request messages (responses/events from elsewhere) are ignored.
  }
  const { id, method, params } = parsed.data;
  const handler = handlers[method];
  if (!handler) {
    send(err(id, `unknown method: ${method}`, "unknown_method"));
    return;
  }
  try {
    const result = await handler(params);
    send(ok(id, result));
  } catch (e) {
    send(err(id, e instanceof Error ? e.message : String(e), "handler_error"));
  }
};

// Bun's stdin is a ReadableStream<Uint8Array>; consume it as an async
// iterator and emit one line at a time as newlines arrive.
for await (const chunk of Bun.stdin.stream()) {
  buffer += decoder.decode(chunk, { stream: true });
  let nl = buffer.indexOf("\n");
  while (nl !== -1) {
    const line = buffer.slice(0, nl).trim();
    buffer = buffer.slice(nl + 1);
    if (line.length > 0) {
      // Fire-and-forget so slow handlers don't head-of-line block the loop.
      // Handlers must not depend on ordering relative to each other.
      void handleLine(line);
    }
    nl = buffer.indexOf("\n");
  }
}
