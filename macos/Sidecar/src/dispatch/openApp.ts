import { z } from "zod";
import { canonicalAppName, resolveAlias } from "./appCatalog.ts";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Launch a macOS application by name. The most common voice command
 * shape by far ("Open Linear", "Launch Chrome", "Start Spotify").
 *
 * The tool is forgiving on the input — it tries the user's spoken
 * name verbatim first, then an alias table (e.g. "chrome" →
 * "Google Chrome", "code" → "Visual Studio Code"), then refuses
 * cleanly if the app isn't installed. The LLM picks this tool when
 * the user wants to launch an app and doesn't need any in-app
 * action; for "open YouTube in my work profile" the model should
 * pick `openInChromeProfile` instead.
 */

const InputShape = {
  name: z.string().min(1, "app name is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const openApp: Tool<Input> = {
  name: "openApp",
  description:
    "Launch a macOS application by name. Accepts the user's spoken name (e.g. 'Linear', 'chrome', 'vs code') — a built-in alias table resolves common nicknames to canonical .app bundle names. If the app isn't installed, returns a clear error. Use this for plain 'open <app>' / 'launch <app>' commands. Do NOT use for opening a URL in an app — use openUrl or openInChromeProfile instead.",
  inputSchema: {
    type: "object",
    properties: {
      name: {
        type: "string",
        description:
          "The app's spoken name. The tool resolves aliases (chrome → Google Chrome, code → Visual Studio Code).",
      },
    },
    required: ["name"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ name }): Promise<ExecutionResult> {
    const aliased = resolveAlias(name);
    const resolved = await canonicalAppName(aliased);
    if (resolved === null) {
      return {
        summary: `${aliased} isn't installed`,
        succeeded: false,
        error: "app_not_installed",
        bashCommands: [],
      };
    }
    const result = await runArgv(["open", "-a", resolved]);
    if (result.exitCode === 0) {
      return {
        summary: `Opened ${resolved}`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't open ${resolved}`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
