import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Compose an email draft via the `mailto:` URL scheme. Every macOS
 * mail client (Apple Mail, Spark, Superhuman, Outlook, Mimestream)
 * registers as a `mailto:` handler, so this dispatches to whichever
 * one the user has set as default — no app-specific AppleScript.
 */

const InputShape = {
  to: z.string().min(1, "recipient is required"),
  subject: z.string().optional(),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const composeMail: Tool<Input> = {
  name: "composeMail",
  description:
    "Open the user's default mail client with a new draft pre-populated with the recipient and optional subject. Use this for 'compose to X', 'email X', 'send X an email about Y', 'draft a note to X'. The body is left blank — the user can dictate it once the draft is focused. Recipients can be names ('alex'), emails ('alex@example.com'), or multiple comma-separated ('alex, jordan').",
  inputSchema: {
    type: "object",
    properties: {
      to: {
        type: "string",
        description:
          "Recipient(s). Names or email addresses; multiple separated by commas.",
      },
      subject: {
        type: "string",
        description: "Optional subject line.",
      },
    },
    required: ["to"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ to, subject }): Promise<ExecutionResult> {
    const url = buildMailtoURL({ to, subject: subject ?? null });
    const result = await runArgv(["open", url]);
    if (result.exitCode === 0) {
      return {
        summary: subject
          ? `Drafting email to ${truncate(to, 30)} — "${truncate(subject, 30)}"`
          : `Drafting email to ${truncate(to, 40)}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: "Couldn't open your mail client",
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

export function buildMailtoURL(action: { to: string; subject: string | null }): string {
  const to = encodeURIComponent(action.to);
  const params: string[] = [];
  if (action.subject !== null) {
    params.push(`subject=${encodeURIComponent(action.subject)}`);
  }
  return params.length === 0 ? `mailto:${to}` : `mailto:${to}?${params.join("&")}`;
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}
