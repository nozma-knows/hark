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
 *   - Trailing politeness words ("open Linear please" → "open linear")
 *
 * Normalizing once in the registry — instead of in each dispatcher —
 * keeps the per-dispatcher regexes simple, lowercase, and DRY.
 */

const TRAILING_PUNCTUATION = /[.,!?;:]+$/;
const TRAILING_POLITENESS = /\s+(?:please|thanks|thank\s+you|for\s+me)$/;
const MULTI_SPACE = /\s+/g;

export function normalize(transcript: string): string {
  let s = transcript.toLowerCase().replace(MULTI_SPACE, " ").trim();
  // Loop until stable: punctuation strip → politeness strip → punctuation
  // strip again. Necessary because "Open Linear, please." needs to first
  // shed the ".", then "please", then the now-exposed ",", in that order.
  let prev = "";
  while (s !== prev) {
    prev = s;
    s = s.replace(TRAILING_PUNCTUATION, "").trim();
    s = s.replace(TRAILING_POLITENESS, "").trim();
  }
  return s;
}
