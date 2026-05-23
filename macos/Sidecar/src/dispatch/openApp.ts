import { canonicalAppName, resolveAlias } from "./appCatalog.ts";
import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Open Linear", "Launch Chrome", "Start Spotify" — the highest-volume
 * voice command shape by far. We only claim the match if the app is
 * actually installed (catalog lookup); a missing app falls through to
 * the LLM fallback so a phrasing like "open my email" can still be
 * interpreted as Mail by Claude.
 *
 * Priority 30 — lower (more specific) dispatchers like chromeProfile
 * (priority 10) can claim phrases that include "open … profile" before
 * we do.
 */

interface OpenAppAction {
  /** The exact bundle name to pass to `open -a`, with original casing. */
  readonly canonical: string;
}

const OPEN_APP_PATTERN = /^(?:open|launch|start)\s+(.+?)\s*(?:\s+app)?$/;

export const openApp: Dispatcher<OpenAppAction> = {
  id: "open-app",
  priority: 30,

  match(transcript) {
    const m = transcript.match(OPEN_APP_PATTERN);
    if (!m) return null;
    const raw = m[1]?.trim();
    if (!raw) return null;

    // Don't claim transcripts that look like a URL — let openUrl handle them.
    if (raw.includes(".") && /\.[a-z]{2,}/.test(raw)) return null;
    // Don't claim "open X in Y profile" — chromeProfile owns that shape.
    if (/\bprofile\b/.test(raw)) return null;

    const aliased = resolveAlias(raw);
    // We can't `await` in a sync `match` — schedule the existence check
    // for `execute()` time. The dispatcher will claim the match and
    // verify at execute time; if the app's gone we return a clear error.
    return { canonical: aliased };
  },

  async execute({ canonical }): Promise<ExecutionResult> {
    const resolved = await canonicalAppName(canonical);
    if (resolved === null) {
      return {
        summary: `${canonical} isn't installed`,
        succeeded: false,
        error: "app_not_installed",
        bashCommands: [],
      };
    }
    const result = await runArgv(["open", "-a", resolved]);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${resolved}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${resolved}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
