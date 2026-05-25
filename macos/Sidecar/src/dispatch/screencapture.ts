import { z } from "zod";
import { homedir } from "node:os";
import { join } from "node:path";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Take a screenshot using macOS's built-in `screencapture`. Default
 * mode is "interactive" — the user picks the area with the standard
 * macOS crosshair, and the file lands on the Desktop with a
 * timestamped name. `fullscreen` captures the whole screen with no UI.
 */

const InputShape = {
  mode: z.enum(["interactive", "fullscreen"]).optional(),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const screenshot: Tool<Input> = {
  name: "screenshot",
  description:
    "Take a screenshot. Default mode is 'interactive' (user picks the area via the standard macOS crosshair). Pass mode='fullscreen' to grab the entire screen with no UI. The file is saved to the Desktop with a timestamped name.",
  inputSchema: {
    type: "object",
    properties: {
      mode: {
        type: "string",
        enum: ["interactive", "fullscreen"],
        description:
          "interactive (default) lets the user pick a region; fullscreen captures everything.",
      },
    },
    required: [],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw ?? {});
  },

  async execute({ mode }): Promise<ExecutionResult> {
    const path = join(homedir(), "Desktop", `screenshot-${timestamp()}.png`);
    const args = mode === "fullscreen" ? ["screencapture", path] : ["screencapture", "-i", path];
    const result = await runArgv(args);
    if (result.exitCode === 0) {
      return {
        summary: `Screenshot saved to ${path}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: "Screenshot cancelled or failed",
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

function timestamp(): string {
  const d = new Date();
  const pad = (n: number) => String(n).padStart(2, "0");
  return [
    d.getFullYear(),
    pad(d.getMonth() + 1),
    pad(d.getDate()),
    "-",
    pad(d.getHours()),
    pad(d.getMinutes()),
    pad(d.getSeconds()),
  ].join("");
}
