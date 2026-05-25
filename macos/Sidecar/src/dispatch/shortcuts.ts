import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Run shortcut Send to Notion" / "Run Send to Notion shortcut" —
 * invokes a user-defined macOS Shortcut by name. The Shortcuts app
 * is forgiving about case but exact about words, so we pass the
 * spoken name through verbatim.
 *
 * Priority 25 (between chromeProfile and openApp) so it claims
 * "run X" before openApp's "start X" sibling regex can.
 *
 * We don't pre-verify the shortcut exists; `shortcuts run` errors
 * out cleanly when it doesn't, and the cost of a `shortcuts list`
 * call is high enough to swamp the speedup the dispatcher gives.
 */

interface ShortcutsAction {
  readonly name: string;
}

const RUN_SHORTCUT = /^run\s+(?:the\s+)?(?:shortcut\s+(.+)|(.+?)\s+shortcut)$/;

export const shortcuts: Dispatcher<ShortcutsAction> = {
  id: "shortcuts",
  priority: 25,

  match(transcript) {
    const m = transcript.match(RUN_SHORTCUT);
    if (!m) return null;
    const name = (m[1] ?? m[2] ?? "").trim();
    if (!name) return null;
    return { name };
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
      errorCode: "bash_failed",
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
