import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Open youtube.com", "Open https://github.com", "Go to twitter dot com",
 * "Visit linear.app" — everything that resolves to a single URL handed
 * to macOS `open`, which picks the user's default browser.
 *
 * Priority 20 (between chromeProfile at 10 and openApp at 30): the
 * presence of a real TLD or scheme is a strong signal that this is
 * URL-shaped, not an app name.
 */

interface OpenUrlAction {
  readonly url: string;
}

// Voice transcripts often render "." as "dot" — handle both shapes.
const URL_OPENER = /^(?:open|go to|navigate to|visit|browse to)\s+(.+?)\s*$/;
// Either an explicit scheme, OR a hostname.tld pattern, OR "word dot tld" voice phrasing.
const URL_LIKE =
  /^(?:https?:\/\/[^\s]+|[a-z0-9][a-z0-9-]*(?:\.[a-z0-9-]+)+(?:\/[^\s]*)?|[a-z0-9-]+(?:\s+dot\s+[a-z0-9-]+)+(?:\/[^\s]*)?)$/i;

export const openUrl: Dispatcher<OpenUrlAction> = {
  id: "open-url",
  priority: 20,

  match(transcript) {
    const m = transcript.match(URL_OPENER);
    if (!m) return null;
    const raw = m[1]?.trim();
    if (!raw) return null;
    if (!URL_LIKE.test(raw)) return null;
    // Don't claim phrases with "in X profile" — chromeProfile owns those.
    if (/\bprofile\b/.test(transcript)) return null;
    return { url: normalizeUrl(raw) };
  },

  async execute({ url }): Promise<ExecutionResult> {
    const result = await runArgv(["open", url]);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${url}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${url}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

/**
 * Normalize voice-flavored URLs:
 *   - "youtube dot com" → "youtube.com"
 *   - "youtube.com"     → "https://youtube.com"
 *   - "https://x.com"   → unchanged
 */
function normalizeUrl(raw: string): string {
  let url = raw.replace(/\s+dot\s+/gi, ".");
  if (!/^https?:\/\//i.test(url)) url = `https://${url}`;
  return url;
}
