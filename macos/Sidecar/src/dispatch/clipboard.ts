import { z } from "zod";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Copy a literal string to the macOS clipboard via `pbcopy`. The LLM
 * picks this when the user says "copy X to my clipboard" or "put X on
 * the clipboard". Doesn't go through `runBash`/`runArgv` because pbcopy
 * reads from stdin and the existing helpers don't support stdin pipes.
 */

const InputShape = {
  text: z.string().min(1, "text must be non-empty"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const clipboardCopy: Tool<Input> = {
  name: "clipboardCopy",
  description:
    "Copy a literal string to the macOS clipboard. Use this when the user wants something specific put on the clipboard ('copy github.com to my clipboard', 'put hello world on the clipboard'). The string is written to pbcopy verbatim — pre-quote / pre-escape if you need to.",
  inputSchema: {
    type: "object",
    properties: {
      text: {
        type: "string",
        description: "The literal text to place on the clipboard.",
      },
    },
    required: ["text"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ text }): Promise<ExecutionResult> {
    const proc = Bun.spawn(["pbcopy"], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: "pipe",
    });
    proc.stdin.write(text);
    await proc.stdin.end();
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const command = `printf %s '<text>' | pbcopy`;
    if (exitCode === 0) {
      return {
        summary: `Copied "${truncate(text, 40)}" to clipboard`,
        succeeded: true,
        bashCommands: [command],
      };
    }
    return {
      summary: "Couldn't copy to clipboard",
      succeeded: false,
      error: stderr.trim() || `exit ${exitCode}`,
      bashCommands: [command],
    };
  },
};

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}
