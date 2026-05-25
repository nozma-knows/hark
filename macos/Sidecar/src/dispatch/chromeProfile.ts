import { z } from "zod";
import { loadChromeProfiles, type ChromeProfile } from "../chromeProfiles.ts";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Open a URL in a specific Google Chrome profile. The LLM picks this
 * when the user names a profile ("…in my work profile", "open YouTube
 * in personal"). The exact list of available profiles is included in
 * the system prompt so the model can pass the right profile name.
 *
 * Profile resolution is forgiving: case-insensitive substring match,
 * so "work" finds "Work (noah@company.com)". If no profile matches,
 * the tool returns a clear error and the model can fall back to plain
 * `openUrl`.
 */

const InputShape = {
  url: z.string().min(1, "url is required"),
  profile: z
    .string()
    .min(1, "profile name is required (use the user-facing Chrome profile name)"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const openInChromeProfile: Tool<Input> = {
  name: "openInChromeProfile",
  description:
    "Open a URL in a specific Google Chrome profile. Use this when the user names a Chrome profile ('in my work profile', 'personal profile'). The available profiles are listed in the system prompt; pass the user-facing profile name. Compose search URLs directly in the url field — e.g., a Gmail search becomes 'https://mail.google.com/mail/u/0/#search/from%3Axfinity'.",
  inputSchema: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description:
          "The URL to open. Scheme will be added if missing. Pre-compose search URLs (Gmail search, Google search, etc.) here instead of opening the home page.",
      },
      profile: {
        type: "string",
        description:
          "The user-facing Chrome profile name (e.g. 'Personal', 'Work'). Matched case-insensitively with substring search.",
      },
    },
    required: ["url", "profile"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ url, profile }): Promise<ExecutionResult> {
    const resolved = await resolveProfile(profile);
    if (resolved === null) {
      return {
        summary: `Couldn't find a Chrome profile matching "${profile}"`,
        succeeded: false,
        error: "profile_not_found",
        bashCommands: [],
      };
    }
    const normalized = normalizeUrl(url);
    const argv = [
      "open",
      "-na",
      "Google Chrome",
      "--args",
      `--profile-directory=${resolved.directory}`,
      normalized,
    ];
    const result = await runArgv(argv);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${normalized} in ${resolved.name}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${normalized} in ${resolved.name}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

async function resolveProfile(spokenName: string): Promise<ChromeProfile | null> {
  const profiles = await loadChromeProfiles();
  if (profiles.length === 0) return null;
  const target = spokenName.toLowerCase().trim();
  for (const p of profiles) {
    if (p.name.toLowerCase() === target) return p;
  }
  for (const p of profiles) {
    if (p.name.toLowerCase().includes(target)) return p;
  }
  return null;
}

function normalizeUrl(raw: string): string {
  let url = raw.trim().replace(/\s+dot\s+/gi, ".");
  if (/^[a-z][a-z0-9+\-.]*:/i.test(url)) return url;
  return `https://${url}`;
}
