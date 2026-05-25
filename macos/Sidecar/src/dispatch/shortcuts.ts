import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Run a user-defined macOS Shortcut by name. The Shortcuts app is
 * forgiving about case but exact about words, so we pass the spoken
 * name through verbatim. We don't pre-verify the shortcut exists —
 * `shortcuts run` errors out cleanly when it doesn't, and the cost
 * of a `shortcuts list` call would swamp the speedup.
 */

const InputShape = {
  name: z.string().min(1, "shortcut name is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const runShortcut: Tool<Input> = {
  name: "runShortcut",
  description:
    "Run one of the user's macOS Shortcuts by name. Use this when the user says 'run shortcut X' or 'run the X shortcut'. The shortcut name is matched by the Shortcuts app — pass it verbatim as the user said it.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description: "The shortcut's name, as the user said it.",
      },
    },
    required: ["name"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ name }): Promise<ExecutionResult> {
    const result = await runArgv(["shortcuts", "run", name]);
    if (result.exitCode === 0) {
      return {
        summary: `Ran shortcut "${name}"`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Shortcut "${name}" failed`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
