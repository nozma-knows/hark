import { loadChromeProfiles, type ChromeProfile } from "../chromeProfiles.ts";
import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Open YouTube in my work profile" / "Open github.com in personal profile".
 *
 * Highest-priority dispatcher (priority 10) because the "in <profile>"
 * suffix is a strong signal — the more general openUrl/openApp regexes
 * would happily eat the phrase without honoring the profile.
 *
 * Profile name resolution is forgiving: case-insensitive, "my X" and
 * "X" both work, partial substring match (so "work" finds "Work
 * (noah@company.com)"). If we can't resolve the named profile we
 * decline the match and let the LLM fallback handle it — better to
 * be safe than open in the wrong profile.
 */

interface ChromeProfileAction {
  readonly url: string;
  readonly profile: ChromeProfile;
}

// "open <target> in (my )? <profile> profile"
const PATTERN = /^(?:open|go to|navigate to|visit|browse to)\s+(.+?)\s+in\s+(?:my\s+)?(.+?)\s+profile\s*$/;

export const chromeProfile: Dispatcher<ChromeProfileAction> = {
  id: "chrome-profile",
  priority: 10,

  // Async work happens in execute; match is sync & pure.
  // We carry the raw profile name through the action and look it up
  // at execute time when the profile loader can be awaited.
  match(transcript) {
    const m = transcript.match(PATTERN);
    if (!m) return null;
    const target = m[1]?.trim();
    const profileName = m[2]?.trim();
    if (!target || !profileName) return null;
    return {
      url: normalizeUrl(target),
      // Defer the profile lookup to execute(); fill with a placeholder
      // that carries the user-spoken name so execute() can resolve it.
      profile: { directory: "", name: profileName },
    };
  },

  async execute({ url, profile }): Promise<ExecutionResult> {
    const resolved = await resolveProfile(profile.name);
    if (resolved === null) {
      return {
        summary: `Couldn't find a Chrome profile matching "${profile.name}"`,
        succeeded: false,
        error: "profile_not_found",
        bashCommands: [],
      };
    }
    const argv = [
      "open",
      "-na",
      "Google Chrome",
      "--args",
      `--profile-directory=${resolved.directory}`,
      url,
    ];
    const result = await runArgv(argv);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${url} in ${resolved.name}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${url} in ${resolved.name}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

async function resolveProfile(spokenName: string): Promise<ChromeProfile | null> {
  const profiles = await loadChromeProfiles();
  if (profiles.length === 0) return null;
  const target = spokenName.toLowerCase();

  // Exact match first
  for (const p of profiles) {
    if (p.name.toLowerCase() === target) return p;
  }
  // Substring match — "work" finds "Work (noah@company.com)"
  for (const p of profiles) {
    if (p.name.toLowerCase().includes(target)) return p;
  }
  return null;
}

function normalizeUrl(raw: string): string {
  let url = raw.replace(/\s+dot\s+/gi, ".");
  if (!/^https?:\/\//i.test(url) && /\.[a-z]{2,}/i.test(url)) {
    url = `https://${url}`;
  }
  return url;
}
