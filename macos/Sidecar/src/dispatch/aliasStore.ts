import { existsSync, readFileSync, statSync } from "node:fs";

/**
 * Persistent store for user-defined voice command aliases. Lives in a
 * JSON file that the Swift app writes to ("Settings → Custom commands"):
 *
 *   $HARK_ALIASES_PATH                                          (override)
 *   ~/Library/Application Support/Hark/aliases.json             (default)
 *
 * The sidecar reads the file with a 1-second mtime cache — fast enough
 * that a transcript-match call doesn't notice it, fresh enough that a
 * user editing aliases sees the change before they finish releasing
 * the Fn key for the next command.
 *
 * Schema (versioned so the Swift writer + sidecar reader can evolve
 * in lockstep):
 *
 *   { "version": 1,
 *     "aliases": [
 *       { "id": "uuid", "phrase": "standup", "commands": ["open -a Zoom", "open -a Slack"] },
 *       ...
 *     ] }
 *
 * Aliases with empty/whitespace phrases or zero commands are silently
 * skipped — the Settings UI prevents creating them but a hand-edited
 * file is a real possibility.
 */

export interface Alias {
  /** Stable id (Swift-side UUID). Used for telemetry, not matching. */
  readonly id: string;
  /** Trigger phrase, lowercased and trimmed. Matched as an exact full string. */
  readonly phrase: string;
  /** Sequence of shell commands to run in order, fail-fast on the first error. */
  readonly commands: ReadonlyArray<string>;
}

interface FileSchema {
  readonly version: number;
  readonly aliases: ReadonlyArray<{
    id?: unknown;
    phrase?: unknown;
    commands?: unknown;
  }>;
}

/**
 * The Swift side writes to one of two locations; this resolves the
 * effective path. Exported so tests can stub the env without juggling
 * process.env directly.
 */
export function aliasFilePath(env: NodeJS.ProcessEnv = process.env): string {
  const override = env.HARK_ALIASES_PATH;
  if (typeof override === "string" && override.length > 0) return override;
  const home = env.HOME ?? "";
  return `${home}/Library/Application Support/Hark/aliases.json`;
}

const CACHE_TTL_MS = 1_000;

/**
 * Load + cache aliases keyed off the file's mtime. Returns an empty
 * array when the file is missing, malformed, or any individual alias
 * fails validation — never throws. The dispatcher would otherwise have
 * to wrap every match() call in a try/catch.
 */
export class AliasStore {
  private cached: ReadonlyArray<Alias> = [];
  private cachedAt = 0;
  private cachedMtimeMs: number | null = null;

  constructor(private readonly resolvePath: () => string = aliasFilePath) {}

  current(): ReadonlyArray<Alias> {
    const now = Date.now();
    if (now - this.cachedAt < CACHE_TTL_MS) return this.cached;
    this.cachedAt = now;

    const path = this.resolvePath();
    if (!existsSync(path)) {
      this.cached = [];
      this.cachedMtimeMs = null;
      return this.cached;
    }
    const mtimeMs = statSync(path).mtimeMs;
    if (mtimeMs === this.cachedMtimeMs) return this.cached;
    this.cachedMtimeMs = mtimeMs;

    try {
      const raw = readFileSync(path, "utf8");
      const json = JSON.parse(raw) as FileSchema;
      this.cached = sanitize(json);
    } catch {
      // Malformed JSON or unreadable file — degrade to "no aliases"
      // rather than crashing the sidecar on every voice command.
      this.cached = [];
    }
    return this.cached;
  }

  /** Test seam — force the next `current()` to re-read the file. */
  invalidate(): void {
    this.cachedAt = 0;
    this.cachedMtimeMs = null;
  }
}

/**
 * Pure validator — accepts the parsed JSON and returns the
 * well-formed aliases. Exported so tests can drive the schema with
 * fixture objects.
 */
export function sanitize(input: unknown): ReadonlyArray<Alias> {
  if (typeof input !== "object" || input === null) return [];
  const file = input as Partial<FileSchema>;
  if (!Array.isArray(file.aliases)) return [];

  const out: Alias[] = [];
  for (const entry of file.aliases) {
    if (typeof entry !== "object" || entry === null) continue;
    const id = typeof entry.id === "string" ? entry.id : null;
    const phraseRaw = typeof entry.phrase === "string" ? entry.phrase : null;
    if (id === null || phraseRaw === null) continue;
    const phrase = phraseRaw.toLowerCase().trim();
    if (phrase.length === 0) continue;
    if (!Array.isArray(entry.commands)) continue;
    const commands: string[] = [];
    for (const cmd of entry.commands) {
      if (typeof cmd !== "string") continue;
      const trimmed = cmd.trim();
      if (trimmed.length === 0) continue;
      commands.push(trimmed);
    }
    if (commands.length === 0) continue;
    out.push({ id, phrase, commands });
  }
  return out;
}

/** Process-wide singleton — created lazily on first dispatch. */
export const defaultAliasStore = new AliasStore();
