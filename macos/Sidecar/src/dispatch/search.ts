import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Search Google for the weather in Tokyo" / "Search YouTube for whisper
 * kit tutorials" / "Search Gmail for emails from xfinity" — known
 * services with a stable search-URL pattern get routed deterministically
 * instead of paying for an LLM round-trip every time.
 *
 * Priority 15 — between chromeProfile (which handles `… in my X profile`)
 * and openUrl. Order matters: "Search Google in my work profile" should
 * route to chromeProfile, not here. We decline transcripts mentioning
 * `profile` so the more specific dispatcher wins.
 *
 * The service registry is the entire extensibility surface: adding a new
 * service is one line in `SERVICES` plus aliases. The LLM fallback still
 * exists for anything not in the registry, so we can ship a small
 * curated list and let Claude handle the long tail.
 */

interface SearchAction {
  readonly service: ServiceKey;
  readonly query: string;
}

type ServiceKey =
  | "google"
  | "youtube"
  | "gmail"
  | "linear"
  | "github"
  | "notion";

interface ServiceDefinition {
  /** Display name used in the pill summary. */
  readonly displayName: string;
  /** URL template; `{q}` is replaced with the encoded query. */
  readonly urlTemplate: string;
  /** Voice-friendly aliases (lowercase, no trailing punctuation). */
  readonly aliases: ReadonlyArray<string>;
}

const SERVICES: Record<ServiceKey, ServiceDefinition> = {
  google: {
    displayName: "Google",
    urlTemplate: "https://www.google.com/search?q={q}",
    aliases: ["google"],
  },
  youtube: {
    displayName: "YouTube",
    urlTemplate: "https://www.youtube.com/results?search_query={q}",
    aliases: ["youtube", "yt"],
  },
  gmail: {
    displayName: "Gmail",
    urlTemplate: "https://mail.google.com/mail/u/0/#search/{q}",
    aliases: ["gmail", "my email", "my inbox", "email"],
  },
  linear: {
    displayName: "Linear",
    urlTemplate: "https://linear.app/search?q={q}",
    aliases: ["linear"],
  },
  github: {
    displayName: "GitHub",
    urlTemplate: "https://github.com/search?q={q}",
    aliases: ["github", "gh"],
  },
  notion: {
    displayName: "Notion",
    urlTemplate: "https://www.notion.so/search?q={q}",
    aliases: ["notion"],
  },
};

/** Build the lookup table once: alias (lowercase) → service key. */
const ALIAS_TO_KEY: ReadonlyMap<string, ServiceKey> = (() => {
  const map = new Map<string, ServiceKey>();
  for (const [key, def] of Object.entries(SERVICES) as Array<
    [ServiceKey, ServiceDefinition]
  >) {
    for (const alias of def.aliases) map.set(alias, key);
  }
  return map;
})();

// Sorted longest-first so multi-word aliases ("my inbox") beat single-word
// substrings ("my") during the prefix match.
const SORTED_ALIASES: ReadonlyArray<string> = Array.from(ALIAS_TO_KEY.keys()).sort(
  (a, b) => b.length - a.length
);

// Verb alternation without filler-word stripping — search aliases like
// "my inbox" / "my email" rely on "my" being preserved as part of the
// service token, unlike openApp where "my" is filler.
const VERB_PREFIX = /^(?:search|find|look\s+up|google|look\s+for)\s+/;
const FOR_SEPARATOR = /\s+for\s+/;

export const search: Dispatcher<SearchAction> = {
  id: "search",
  priority: 15,

  match(transcript) {
    // "open X in Y profile" — let chromeProfile own these.
    if (/\bprofile\b/.test(transcript)) return null;

    // Strip the leading verb if present. We accept the shortcut form
    // "google <query>" (no "for" needed) since that's a natural voice
    // phrasing; for other services the "for" separator disambiguates
    // the service from the query.
    const verbStripped = transcript.replace(VERB_PREFIX, "");
    if (verbStripped === transcript && !/^google\s+/.test(transcript)) {
      // Verb didn't match — only the "google X" shortcut bypasses the verb.
      return null;
    }

    // Two shapes to recognize:
    //   1. "<service> for <query>"          — e.g. "youtube for whisper kit"
    //   2. "google <query>"                 — shortcut verb directly to Google
    const forMatch = verbStripped.match(FOR_SEPARATOR);
    if (forMatch?.index !== undefined) {
      const head = verbStripped.slice(0, forMatch.index).trim();
      const tail = verbStripped.slice(forMatch.index + forMatch[0].length).trim();
      const serviceKey = resolveService(head);
      if (serviceKey && tail.length > 0) {
        return { service: serviceKey, query: tail };
      }
      return null;
    }

    // "google <query>" — only Google supports the leading-verb shortcut.
    const googleShortcut = transcript.match(/^google\s+(.+)$/);
    if (googleShortcut?.[1]) {
      return { service: "google", query: googleShortcut[1].trim() };
    }
    return null;
  },

  async execute({ service, query }): Promise<ExecutionResult> {
    const def = SERVICES[service];
    const url = def.urlTemplate.replace("{q}", encodeURIComponent(query));
    const result = await runArgv(["open", url]);
    if (result.exitCode === 0) {
      return {
        summary: `Searched ${def.displayName} for "${truncate(query, 40)}"`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${def.displayName} search`,
      succeeded: false,
      errorCode: "bash_failed",
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

/** Match the longest-known alias appearing at the start of `head`. */
function resolveService(head: string): ServiceKey | null {
  const t = head.toLowerCase().trim();
  for (const alias of SORTED_ALIASES) {
    if (t === alias) return ALIAS_TO_KEY.get(alias) ?? null;
  }
  return null;
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}

/** Exposed for the registry test so it can confirm the full alias set. */
export const _servicesForTests = SERVICES;
