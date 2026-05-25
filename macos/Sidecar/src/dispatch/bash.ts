import { z } from "zod";
import { runBash } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Escape-hatch tool — runs an arbitrary bash command. Used for everything
 * the structured tools don't cover (custom AppleScripts, ad-hoc CLIs,
 * chained operations). Lower-priority than the structured tools as far
 * as the model is concerned: the description tells it to prefer the
 * narrow tools when one fits.
 *
 * The deny-list in `runBash.ts` still applies — destructive patterns
 * (rm -rf, sudo, dd) are refused at execution time regardless of which
 * code path drove the call.
 */

const InputShape = {
  command: z.string().min(1, "command must be a non-empty string"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const bash: Tool<Input> = {
  name: "bash",
  description:
    "Run an arbitrary bash command on macOS. Use this ONLY when no other tool fits — prefer the structured tools (openApp, openUrl, search, runShortcut, etc.) when one applies. Examples: an AppleScript that no other tool wraps, a one-liner that combines multiple actions, or a CLI specific to the user's setup. Do not chain commands with `&&` unless you have to.",
  inputSchema: {
    type: "object",
    properties: {
      command: {
        type: "string",
        description: "The bash command to execute.",
      },
    },
    required: ["command"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ command }): Promise<ExecutionResult> {
    const r = await runBash(command);
    if (r.exitCode === 0 && !r.timedOut) {
      return {
        summary: `Ran: ${truncate(command, 60)}`,
        succeeded: true,
        bashCommands: [command],
      };
    }
    return {
      summary: r.timedOut
        ? `Command timed out: ${truncate(command, 60)}`
        : `Command failed (exit ${r.exitCode})`,
      succeeded: false,
      error: r.stderr.trim() || `exit ${r.exitCode}`,
      bashCommands: [command],
    };
  },
};

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}
