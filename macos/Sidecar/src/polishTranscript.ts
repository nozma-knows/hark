import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/**
 * Post-process a raw Whisper transcript using Claude. Adds punctuation +
 * casing, removes obvious filler, fixes homophones — without paraphrasing
 * or expanding. The goal is "what you said, just cleaned up", not
 * "Claude's interpretation of what you said".
 */

export const PolishTranscriptParams = z.object({
  text: z.string().min(1),
});
export type PolishTranscriptParams = z.infer<typeof PolishTranscriptParams>;

export interface PolishTranscriptResult {
  polished: string;
  /** Whether Claude actually produced a different string than the input. */
  changed: boolean;
  /** Token usage from the underlying Claude call. Camel-case for the Swift Codable.
   *  Explicit `| undefined` because the tsconfig enables exactOptionalPropertyTypes —
   *  without it, returning `undefined` for this field requires omitting the key. */
  usage?: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
  } | undefined;
}

const SYSTEM_PROMPT = `You post-process raw dictation transcripts from Whisper. Clean the input up so it reads naturally without changing what the user said.

DO:
- Add correct sentence punctuation and capitalization.
- Capitalize the pronoun "I" and proper nouns when clear from context.
- Remove obvious filler words ("um", "uh", "like" used as filler, restarted false-starts).
- Fix obvious homophone mistakes from context (their/there/they're, your/you're, to/too/two, its/it's).
- Preserve technical terms, names, and quoted phrases exactly.

DO NOT:
- Paraphrase, summarize, expand, or rewrite for style.
- Add information that wasn't spoken.
- Wrap the result in quotes, code blocks, or markdown.
- Add commentary, preambles, or explanations.

Output ONLY the cleaned transcript text. Nothing else.`;

export async function polishTranscript(
  raw: unknown,
): Promise<PolishTranscriptResult> {
  const { text } = PolishTranscriptParams.parse(raw);

  // Single-shot prompt — no tools, no follow-ups. Claude reads the dictation
  // and emits the cleaned version.
  let polished = "";
  let usage: PolishTranscriptResult["usage"];
  const claudeBinary = process.env.HARK_CLAUDE_BINARY;
  for await (const message of query({
    prompt: `${SYSTEM_PROMPT}\n\nRaw dictation:\n${text}`,
    options: {
      maxTurns: 1,
      ...(claudeBinary ? { pathToClaudeCodeExecutable: claudeBinary } : {}),
    },
  }) as AsyncIterable<SDKMessage>) {
    if (message.type === "result" && message.subtype === "success") {
      polished = message.result;
      // The result message carries cumulative usage for the call. Field
      // names follow Anthropic's API; we re-key into camelCase for Swift.
      const u = (message as unknown as { usage?: Record<string, number> }).usage;
      if (u) {
        usage = {
          inputTokens: Number(u.input_tokens ?? 0),
          outputTokens: Number(u.output_tokens ?? 0),
          cacheReadTokens: Number(u.cache_read_input_tokens ?? 0),
          cacheCreationTokens: Number(u.cache_creation_input_tokens ?? 0),
        };
      }
    }
  }

  const cleaned = polished.trim();
  if (cleaned.length === 0) {
    // Fall back to raw rather than dropping the user's words on the floor.
    return { polished: text, changed: false, usage };
  }
  return { polished: cleaned, changed: cleaned !== text, usage };
}
