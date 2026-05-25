import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Search a known web service for a query and open the result page in
 * the user's default browser. The LLM picks this for "Search Google
 * for X", "Find Y in Linear", "Look up Z on GitHub". For unknown
 * services the model should fall back to `openUrl` with a manually
 * composed search URL.
 *
 * The service set is intentionally small — extending it is one entry
 * in `SERVICES`. The LLM doesn't need every long-tail service hardcoded
 * because it can always pre-compose search URLs and call `openUrl`.
 */

type ServiceKey =
  | "google"
  | "youtube"
  | "gmail"
  | "linear"
  | "github"
  | "notion";

interface ServiceDefinition {
  readonly displayName: string;
  readonly urlTemplate: string;
}

const SERVICES: Record<ServiceKey, ServiceDefinition> = {
  google: {
    displayName: "Google",
    urlTemplate: "https://www.google.com/search?q={q}",
  },
  youtube: {
    displayName: "YouTube",
    urlTemplate: "https://www.youtube.com/results?search_query={q}",
  },
  gmail: {
    displayName: "Gmail",
    urlTemplate: "https://mail.google.com/mail/u/0/#search/{q}",
  },
  linear: {
    displayName: "Linear",
    urlTemplate: "https://linear.app/search?q={q}",
  },
  github: {
    displayName: "GitHub",
    urlTemplate: "https://github.com/search?q={q}",
  },
  notion: {
    displayName: "Notion",
    urlTemplate: "https://www.notion.so/search?q={q}",
  },
};

const InputShape = {
  service: z.enum(["google", "youtube", "gmail", "linear", "github", "notion"]),
  query: z.string().min(1, "query is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const search: Tool<Input> = {
  name: "search",
  description:
    "Search a known web service and open the result page. Supported services: google, youtube, gmail, linear, github, notion. The query is URL-encoded for you. For services not on this list, use openUrl with a manually-composed search URL instead.",
  inputSchema: {
    type: "object",
    properties: {
      service: {
        type: "string",
        enum: Object.keys(SERVICES),
        description: "The service to search.",
      },
      query: {
        type: "string",
        description: "The search query, raw — encoding is handled by the tool.",
      },
    },
    required: ["service", "query"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
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
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}

/** Exposed for tests so the alias set can be asserted. */
export const _servicesForTests = SERVICES;
