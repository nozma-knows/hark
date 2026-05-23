import { chromeProfile } from "./chromeProfile.ts";
import { clipboard } from "./clipboard.ts";
import { music } from "./music.ts";
import { normalize } from "./normalize.ts";
import { openApp } from "./openApp.ts";
import { openUrl } from "./openUrl.ts";
import { screencapture } from "./screencapture.ts";
import { search } from "./search.ts";
import { shortcuts } from "./shortcuts.ts";
import { asEntry, type ExecutionResult, type RegistryEntry } from "./types.ts";

/**
 * Ordered dispatcher registry. First non-null match wins.
 *
 * Lower priority = more specific = runs first. Concrete ordering today:
 *
 *   10  chromeProfile   — "open X in <name> profile"
 *   15  search          — "search <service> for <query>"
 *   20  openUrl         — "open <URL>" / "go to <site>"
 *   25  shortcuts       — "run shortcut X"
 *   30  openApp         — "open <app>"
 *   35  music           — "play music", "next song", "pause"
 *   40  screencapture   — "take a screenshot"
 *   40  clipboard       — "copy X to clipboard"
 *
 * Adding a new dispatcher: write `src/dispatch/<id>.ts` exporting a
 * `Dispatcher<TAction>`, import it here, wrap with `asEntry()`, and
 * insert at the right priority. No other file changes.
 */
const ENTRIES: ReadonlyArray<RegistryEntry> = [
  asEntry(chromeProfile),
  asEntry(search),
  asEntry(openUrl),
  asEntry(shortcuts),
  asEntry(openApp),
  asEntry(music),
  asEntry(screencapture),
  asEntry(clipboard),
].sort((a, b) => a.priority - b.priority);

export interface DispatcherMatch {
  readonly id: string;
  /** Pre-bound executor that runs the matched action. */
  readonly execute: () => Promise<ExecutionResult>;
}

/**
 * Run the transcript through every dispatcher's `match()` in priority
 * order; return the first hit along with a pre-bound executor, or null
 * if nothing claimed the transcript. Caller (executeCommand) is
 * responsible for actually calling `execute()` — keeps the dispatcher
 * path identifiable in telemetry before any side effects happen.
 */
export function tryMatch(transcript: string): DispatcherMatch | null {
  const normalized = normalize(transcript);
  for (const entry of ENTRIES) {
    const executor = entry.tryMatch(normalized);
    if (executor !== null) {
      return { id: entry.id, execute: executor };
    }
  }
  return null;
}

/**
 * Read-only view of the registry for tests and the eventual settings
 * UI ("which dispatchers are wired in this build?").
 */
export const _entriesForTests: ReadonlyArray<RegistryEntry> = ENTRIES;
