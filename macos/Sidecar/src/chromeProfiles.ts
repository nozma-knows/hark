import { promises as fs } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";

/**
 * Resolve Chrome's on-disk profile directories (`Default`, `Profile 1`, …)
 * to the human-readable names the user sees in the Chrome menu
 * (`Personal`, `Work`, …). Chrome stores this mapping in
 * `~/Library/Application Support/Google/Chrome/Local State`, in
 * `profile.info_cache[<dir>].name`.
 *
 * We pre-load it once per sidecar invocation (cheap: it's a small JSON
 * file) and bake the mapping into the system prompt so Claude can pick
 * the right `--profile-directory` flag without needing a tool call.
 */

export interface ChromeProfile {
  /** On-disk directory name — what `--profile-directory` wants. */
  directory: string;
  /** User-facing name from Chrome's profile chooser. */
  name: string;
}

const LOCAL_STATE = join(
  homedir(),
  "Library/Application Support/Google/Chrome/Local State"
);

const CACHE_TTL_MS = 5 * 60 * 1000;
let cached: { at: number; profiles: ChromeProfile[] } | null = null;

export async function loadChromeProfiles(): Promise<ChromeProfile[]> {
  if (cached && Date.now() - cached.at < CACHE_TTL_MS) {
    return cached.profiles;
  }

  let profiles: ChromeProfile[] = [];
  try {
    const raw = await fs.readFile(LOCAL_STATE, "utf-8");
    const json = JSON.parse(raw) as {
      profile?: { info_cache?: Record<string, { name?: string }> };
    };
    const infoCache = json.profile?.info_cache ?? {};
    profiles = Object.entries(infoCache).map(([directory, info]) => ({
      directory,
      name: typeof info?.name === "string" && info.name.length > 0
        ? info.name
        : directory,
    }));
    // Chrome lists in the order they were created; surface a stable order
    // alphabetised by user-facing name.
    profiles.sort((a, b) => a.name.localeCompare(b.name));
  } catch {
    // Chrome not installed, file missing, or malformed JSON — return nothing
    // and let the SYSTEM_PROMPT fall through without the profiles section.
    profiles = [];
  }

  cached = { at: Date.now(), profiles };
  return profiles;
}

/**
 * Format the mapping for inclusion in a Claude system prompt. Returns an
 * empty string when no profiles are detected (Chrome not installed).
 */
export function formatChromeProfilesForPrompt(profiles: ChromeProfile[]): string {
  if (profiles.length === 0) return "";
  const lines = profiles
    .map((p) => `  - "${p.name}" → --profile-directory="${p.directory}"`)
    .join("\n");
  return `\nGoogle Chrome profiles on this Mac (use the right --profile-directory flag based on the user's wording):\n${lines}\n`;
}
