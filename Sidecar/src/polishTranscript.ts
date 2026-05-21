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
  for await (const message of query({
    prompt: `${SYSTEM_PROMPT}\n\nRaw dictation:\n${text}`,
    options: {
      maxTurns: 1,
    },
  }) as AsyncIterable<SDKMessage>) {
    if (message.type === "result" && message.subtype === "success") {
      polished = message.result;
    }
  }

  const cleaned = polished.trim();
  if (cleaned.length === 0) {
    // Fall back to raw rather than dropping the user's words on the floor.
    return { polished: text, changed: false };
  }
  return { polished: cleaned, changed: cleaned !== text };
}
