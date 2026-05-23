/**
 * Whisper's output is mostly clean but reliably has a few quirks
 * that would otherwise force every dispatcher's regex to handle
 * them independently:
 *
 *   - Trailing period / question mark / exclamation point
 *     ("open Linear." → "open Linear")
 *   - Title-case proper nouns ("Open Linear" → "open linear")
 *   - Doubled spaces from disfluencies ("open  linear")
 *   - Leading/trailing whitespace
 *
 * Normalizing once in the registry — instead of in each dispatcher —
 * keeps the per-dispatcher regexes simple, lowercase, and DRY.
 */

const TRAILING_PUNCTUATION = /[.,!?;:]+$/;
const MULTI_SPACE = /\s+/g;

export function normalize(transcript: string): string {
  return transcript
    .toLowerCase()
    .replace(TRAILING_PUNCTUATION, "")
    .replace(MULTI_SPACE, " ")
    .trim();
}
