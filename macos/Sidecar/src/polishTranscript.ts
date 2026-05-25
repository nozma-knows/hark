import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

/**
 * Post-process a raw Whisper transcript using Claude. Adds punctuation +
 * casing, removes obvious filler, fixes homophones — without paraphrasing
 * or expanding. The goal is "what you said, just cleaned up", not
 * "Claude's interpretation of what you said".
 *
 * Profiles let the polish adapt tone to where the text will land:
 *
 *   - `standard` — punctuation + casing + filler only, no tone change.
 *   - `casual`   — Slack / iMessage feel; contractions preserved.
 *   - `formal`   — Email / docs; contractions expanded.
 *   - `code`     — IDE / terminal; technical identifiers protected.
 *
 * The Swift side picks the profile per frontmost app and passes it on
 * each `polishTranscript` request. Unknown / missing values fall back
 * to `standard` so a Swift-side typo can't cause a hard failure.
 */

export const POLISH_PROFILES = ["standard", "casual", "formal", "code"] as const;
export type PolishProfile = (typeof POLISH_PROFILES)[number];

const STANDARD_PROMPT = `You post-process raw dictation transcripts from Whisper. Clean the input up so it reads naturally without changing what the user said.

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

const CASUAL_PROMPT = `You post-process raw dictation transcripts from Whisper for a CASUAL context — Slack, iMessage, Discord, a quick reply. Keep it informal and short.

DO:
- Add correct punctuation and capitalization.
- Keep contractions ("don't", "we're", "I'll") — that's the natural register here.
- Remove obvious filler ("um", "uh", restarted false-starts).
- Fix obvious homophone mistakes.
- Preserve technical terms, names, and quoted phrases exactly.
- Short fragments are fine — don't force complete sentences.

DO NOT:
- Paraphrase, summarize, or rewrite for style.
- Add emoji.
- Expand contractions.
- Wrap the result in quotes, code blocks, or markdown.
- Add commentary, preambles, or explanations.

Output ONLY the cleaned transcript text. Nothing else.`;

const FORMAL_PROMPT = `You post-process raw dictation transcripts from Whisper for a FORMAL context — email, docs, a Notes entry the user might keep. Treat it like written prose.

DO:
- Add correct punctuation and capitalization.
- Expand contractions where natural ("don't" → "do not", "we're" → "we are").
- Use complete sentences. Connect short clauses with appropriate punctuation.
- Remove obvious filler ("um", "uh", restarted false-starts).
- Fix obvious homophone mistakes.
- Preserve technical terms, names, and quoted phrases exactly.

DO NOT:
- Paraphrase, summarize, or rewrite the user's argument.
- Add information that wasn't spoken.
- Wrap the result in quotes, code blocks, or markdown.
- Add commentary, preambles, or explanations.

Output ONLY the cleaned transcript text. Nothing else.`;

const CODE_PROMPT = `You post-process raw dictation transcripts from Whisper for a CODE-ADJACENT context — IDE comments, commit messages, terminal prompts. Technical correctness over prose flow.

DO:
- Add correct punctuation and capitalization.
- Preserve technical identifiers VERBATIM (function names, variable names, file paths, CLI verbs, env vars).
- Preserve shell-style verbs ("rm", "grep", "ls", "git") exactly as spoken — never "fix" them into prose.
- Fix obvious homophone mistakes only when they're clearly NOT code.
- Remove obvious filler ("um", "uh", restarted false-starts).

DO NOT:
- Expand technical abbreviations (keep "fn", "cfg", "auth" as-is when context is technical).
- Paraphrase or summarize.
- Wrap the result in quotes, code blocks, or markdown.
- Add commentary, preambles, or explanations.

Output ONLY the cleaned transcript text. Nothing else.`;

export const PROFILE_PROMPTS: Record<PolishProfile, string> = {
  standard: STANDARD_PROMPT,
  casual: CASUAL_PROMPT,
  formal: FORMAL_PROMPT,
  code: CODE_PROMPT,
};

/**
 * Normalise an incoming profile name to one of the canonical values.
 * Anything we don't recognise (typos, future profiles the Swift side
 * shipped against an older sidecar, undefined / non-string) lands on
 * `standard` — preserves backward compatibility.
 */
export function resolveProfile(raw: unknown): PolishProfile {
  if (typeof raw !== "string") return "standard";
  return (POLISH_PROFILES as ReadonlyArray<string>).includes(raw)
    ? (raw as PolishProfile)
    : "standard";
}

export const PolishTranscriptParams = z.object({
  text: z.string().min(1),
  profile: z.string().optional(),
});
export type PolishTranscriptParams = z.infer<typeof PolishTranscriptParams>;

export interface PolishTranscriptResult {
  polished: string;
  /** Whether Claude actually produced a different string than the input. */
  changed: boolean;
  /** Profile actually applied (post-resolve). Surfaced so the Swift side
   *  can confirm the override took effect in diagnostics. */
  profile: PolishProfile;
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

export async function polishTranscript(
  raw: unknown,
): Promise<PolishTranscriptResult> {
  const { text, profile: requestedProfile } = PolishTranscriptParams.parse(raw);
  const profile = resolveProfile(requestedProfile);
  const systemPrompt = PROFILE_PROMPTS[profile];

  // Single-shot prompt — no tools, no follow-ups. Claude reads the dictation
  // and emits the cleaned version.
  let polished = "";
  let usage: PolishTranscriptResult["usage"];
  const claudeBinary = process.env.HARK_CLAUDE_BINARY;
  for await (const message of query({
    prompt: `${systemPrompt}\n\nRaw dictation:\n${text}`,
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
    return { polished: text, changed: false, profile, usage };
  }
  return { polished: cleaned, changed: cleaned !== text, profile, usage };
}
