import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Enumerate the macOS apps installed under `/Applications` and
 * `~/Applications` so dispatchers can refuse to claim a match for
 * an app the user doesn't actually have. Without this, "open Linear"
 * on a machine without Linear installed would dispatch to
 * `open -a Linear` which exits 0 (LaunchServices "succeeds" at
 * deciding-it-can't-find-the-app) but nothing visible happens —
 * the very fake-success failure mode this PR is trying to kill.
 *
 * Cached for the sidecar process lifetime. Apps install/uninstall
 * is rare on the timescale of a single Hark session; we trade a
 * small staleness window for sub-millisecond lookups.
 *
 * Alias map handles the common case where a user calls an app
 * by a colloquial name ("chrome") that doesn't exactly match the
 * `.app` bundle name ("Google Chrome"). Aliases resolve before
 * existence check.
 */

/** Common voice → canonical bundle name mappings. */
const ALIASES: Record<string, string> = {
  chrome: "Google Chrome",
  "google chrome": "Google Chrome",
  vscode: "Visual Studio Code",
  "vs code": "Visual Studio Code",
  "visual studio code": "Visual Studio Code",
  code: "Visual Studio Code",
  cursor: "Cursor",
  arc: "Arc",
  safari: "Safari",
  firefox: "Firefox",
  linear: "Linear",
  notion: "Notion",
  slack: "Slack",
  spotify: "Spotify",
  music: "Music",
  mail: "Mail",
  notes: "Notes",
  reminders: "Reminders",
  calendar: "Calendar",
  messages: "Messages",
  finder: "Finder",
  terminal: "Terminal",
  iterm: "iTerm",
  iterm2: "iTerm",
  zoom: "zoom.us",
  figma: "Figma",
  discord: "Discord",
  obsidian: "Obsidian",
  raycast: "Raycast",
  "1password": "1Password",
  superhuman: "Superhuman",
};

/**
 * Apply the alias table. If no alias matches, return the input with
 * each word title-cased — a reasonable guess for "open foobar" → "Foobar".
 * The canonical-name check downstream will verify the guess against the
 * actual installed apps; a wrong guess just falls through to LLM fallback.
 */
export function resolveAlias(name: string): string {
  const lower = name.toLowerCase().trim();
  const aliased = ALIASES[lower];
  if (aliased) return aliased;
  return titleCase(lower);
}

function titleCase(s: string): string {
  return s
    .split(/\s+/)
    .map((w) => (w.length === 0 ? w : w[0]!.toUpperCase() + w.slice(1)))
    .join(" ");
}

const SEARCH_PATHS = [
  "/Applications",
  "/System/Applications",
  join(homedir(), "Applications"),
];

let cache: Promise<Map<string, string>> | null = null;

/**
 * Lazily-loaded catalog. Key is lowercased base name (without `.app`),
 * value is the canonical name (with original case) suitable for
 * `open -a "<Name>"`. Singleton — the promise is reused across calls.
 */
function loadCatalog(): Promise<Map<string, string>> {
  if (cache) return cache;
  cache = (async () => {
    const map = new Map<string, string>();
    for (const dir of SEARCH_PATHS) {
      try {
        const entries = await fs.readdir(dir);
        for (const entry of entries) {
          if (!entry.endsWith(".app")) continue;
          const base = entry.slice(0, -".app".length);
          const key = base.toLowerCase();
          // First-found wins so /Applications shadows /System/Applications
          // when both contain a Mail.app etc.
          if (!map.has(key)) map.set(key, base);
        }
      } catch {
        // Directory doesn't exist (rare on /Applications, common
        // for ~/Applications) — skip silently.
      }
    }
    return map;
  })();
  return cache;
}

/**
 * Does the user have an app whose `.app` base name matches `name`,
 * case-insensitively? Returns the canonical name (the case the
 * `open -a` argument should use) or null if not found.
 */
export async function canonicalAppName(name: string): Promise<string | null> {
  const catalog = await loadCatalog();
  return catalog.get(name.toLowerCase()) ?? null;
}

/** Convenience: does this app exist on the user's machine? */
export async function appExists(name: string): Promise<boolean> {
  return (await canonicalAppName(name)) !== null;
}

/**
 * Reset the cache. Tests use this to force a re-scan with mocked
 * filesystem state; production code should never call it.
 */
export function _resetCatalogForTests(): void {
  cache = null;
}
