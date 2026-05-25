import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Open a URL in the user's default browser. The LLM picks this for
 * any phrasing that resolves to a single URL: "Open youtube.com",
 * "Go to https://github.com", "Visit linear.app". When the user
 * names a specific Chrome profile ("…in my work profile"), the model
 * should pick `openInChromeProfile` instead.
 *
 * The tool normalises voice quirks — "youtube dot com" → "youtube.com"
 * — and prefixes `https://` if the input lacks a scheme.
 */

const InputShape = {
  url: z.string().min(1, "url is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const openUrl: Tool<Input> = {
  name: "openUrl",
  description:
    "Open a URL in the user's default browser. Accepts bare hostnames ('github.com'), spoken-form hostnames ('youtube dot com'), or fully-qualified URLs ('https://linear.app/issue/ENG-100'). The tool will add 'https://' if missing. Use this for plain navigation; use openInChromeProfile when the user names a Chrome profile, and use search when the user wants to query a service.",
  inputSchema: {
    type: "object",
    properties: {
      url: {
        type: "string",
        description:
          "The URL or hostname to open. Scheme will be added if missing.",
      },
    },
    required: ["url"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ url }): Promise<ExecutionResult> {
    const normalized = normalizeUrl(url);
    const result = await runArgv(["open", normalized]);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${normalized}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${normalized}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

function normalizeUrl(raw: string): string {
  let url = raw.trim().replace(/\s+dot\s+/gi, ".");
  // Allow app schemes (linear://, notion://, raycast://) verbatim.
  if (/^[a-z][a-z0-9+\-.]*:/i.test(url)) return url;
  return `https://${url}`;
}
