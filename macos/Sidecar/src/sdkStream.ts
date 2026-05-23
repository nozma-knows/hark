/**
 * Pure consumer of a Claude Agent SDK message stream. Pulled out of
 * `executeCommand.ts` so the verification logic — "did Bash actually
 * run, or did Claude Code silently deny the tool call?" — is unit
 * testable without spinning up the real `query()` subprocess.
 *
 * Why the verification matters: Claude Code reads the user's local
 * `~/.claude/settings.json` and applies permission rules to tool
 * calls. In a headless sidecar context with `defaultMode: "auto"`
 * and no allow-listed `Bash(open:*)`, the auto classifier denies
 * the tool call. The SDK swallows the denial and the assistant
 * happily generates "Opened Linear" anyway — a fake success that
 * leaves the user staring at a pill while nothing happened on
 * screen. See Mac #2 bug.
 *
 * Contract: we count every `tool_use` block from assistant messages
 * and every successful result. If a `result` arrives with
 * `subtype === "success"` but zero `tool_use` blocks were observed,
 * we override the success to `false` with a specific error code so
 * the pill shows a real failure instead of a silent lie.
 */

export interface SdkStreamSummary {
  /** The text the agent emitted in its final result message. */
  summary: string;
  /** True only if the SDK said success AND at least one Bash tool_use ran. */
  succeeded: boolean;
  /** Set when `succeeded` is false to disambiguate which failure path fired.
   *  Explicit `| undefined` because the tsconfig enables
   *  exactOptionalPropertyTypes — without it, passing `undefined` to the
   *  field requires omitting the key entirely. */
  errorCode?: SdkErrorCode | undefined;
  /** Every command Claude asked us to run, in invocation order. */
  bashCommands: string[];
  /** Total assistant turns the SDK emitted (one assistant message = one turn). */
  llmTurns: number;
  /** Token usage from the final result message, if the SDK reported any. */
  usage?: ClaudeUsage | undefined;
}

export type SdkErrorCode =
  /** Claude Code denied Bash via the user's settings.json — fake success caught. */
  | "claude_code_denied_bash"
  /** SDK emitted an error result subtype. */
  | "sdk_error"
  /** SDK ended without a result message. */
  | "no_result"
  /** SDK returned success but with empty summary text. */
  | "empty_summary";

export interface ClaudeUsage {
  inputTokens: number;
  outputTokens: number;
  cacheReadTokens: number;
  cacheCreationTokens: number;
}

/**
 * Drain an async iterable of SDK messages and produce a verified
 * summary. Doesn't throw — every failure mode maps to a structured
 * `SdkStreamSummary` so the caller can render a pill without
 * worrying about catch blocks.
 */
export async function consumeSdkStream(
  messages: AsyncIterable<unknown>
): Promise<SdkStreamSummary> {
  const bashCommands: string[] = [];
  let llmTurns = 0;
  let summary = "";
  let succeeded = false;
  let errorCode: SdkErrorCode | undefined;
  let usage: ClaudeUsage | undefined;

  for await (const raw of messages) {
    // The SDK's exported types narrow `message.message.content` differently
    // across versions; we treat each message as a loose record and only
    // touch the fields we know exist. This keeps the consumer resilient
    // to SDK upgrades that add fields we don't use yet.
    const m = raw as unknown as Record<string, unknown>;

    if (m.type === "assistant") {
      llmTurns++;
      const content = extractContentBlocks(m);
      for (const block of content) {
        if (block.type === "tool_use" && isBashLikeTool(block.name)) {
          const command = extractBashCommand(block.input);
          if (command !== null) bashCommands.push(command);
        }
      }
      continue;
    }

    if (m.type === "result") {
      const subtype = typeof m.subtype === "string" ? m.subtype : undefined;
      const resultText = typeof m.result === "string" ? m.result : "";
      const errorText = typeof m.error === "string" ? m.error : "";

      if (subtype === "success") {
        summary = resultText.trim();
        succeeded = true;
      } else {
        summary = (errorText || "Command failed").trim();
        succeeded = false;
        errorCode = "sdk_error";
      }

      const rawUsage = m.usage as Record<string, unknown> | undefined;
      if (rawUsage) {
        usage = {
          inputTokens: numericField(rawUsage.input_tokens),
          outputTokens: numericField(rawUsage.output_tokens),
          cacheReadTokens: numericField(rawUsage.cache_read_input_tokens),
          cacheCreationTokens: numericField(rawUsage.cache_creation_input_tokens),
        };
      }
    }
  }

  // Post-stream verification. Anything that bypassed Bash in a
  // permission-restricted environment lands here.
  if (!summary) {
    succeeded = false;
    errorCode ??= "no_result";
    summary = "Agent returned no summary";
  } else if (succeeded && bashCommands.length === 0) {
    // The success-with-no-tool-use signature. Claude Code denied
    // Bash; SDK suppressed the denial; assistant narrated as if it
    // had run. Override with a concrete error the user can act on.
    succeeded = false;
    errorCode = "claude_code_denied_bash";
    summary = "Couldn't run the command. Check ~/.claude/settings.json — Bash may be denied for this app.";
  }

  return { summary, succeeded, errorCode, bashCommands, llmTurns, usage };
}

/** Pull `content` out of either `message.content` or `message.message.content`. */
function extractContentBlocks(m: Record<string, unknown>): ContentBlock[] {
  const direct = m.content;
  if (Array.isArray(direct)) return direct as ContentBlock[];
  const nested = (m.message as Record<string, unknown> | undefined)?.content;
  if (Array.isArray(nested)) return nested as ContentBlock[];
  return [];
}

interface ContentBlock {
  type: string;
  name?: string;
  input?: unknown;
}

/** Bash and shell-running tools all look the same to us — accept loose names. */
function isBashLikeTool(name: string | undefined): boolean {
  if (!name) return false;
  const n = name.toLowerCase();
  return n === "bash" || n === "shell" || n === "execute";
}

/** Tool input shape: `{ command: "open -a Linear" }` for Bash. */
function extractBashCommand(input: unknown): string | null {
  if (!input || typeof input !== "object") return null;
  const cmd = (input as Record<string, unknown>).command;
  return typeof cmd === "string" && cmd.length > 0 ? cmd : null;
}

function numericField(v: unknown): number {
  return typeof v === "number" && Number.isFinite(v) ? v : 0;
}
