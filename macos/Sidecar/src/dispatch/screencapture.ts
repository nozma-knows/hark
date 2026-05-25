import { homedir } from "node:os";
import { join } from "node:path";
import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Take a screenshot" / "Screenshot" / "Capture the screen" — the
 * single most common voice command on a Mac after "open X". Uses
 * macOS's built-in `screencapture -i` (interactive) so the user
 * picks the area; the file lands on Desktop with a timestamped name.
 *
 * Priority 40 (broad pattern; runs after the more-specific ones).
 */

interface ScreencaptureAction {
  /** Marker — no fields needed today, but typed for future "fullscreen" etc. */
  readonly kind: "interactive";
}

const PATTERNS: ReadonlyArray<RegExp> = [
  /^take (?:a )?screenshot$/,
  /^screenshot$/,
  /^capture (?:the )?screen$/,
  /^grab (?:a )?screenshot$/,
];

export const screencapture: Dispatcher<ScreencaptureAction> = {
  id: "screencapture",
  priority: 40,

  match(transcript) {
    for (const p of PATTERNS) {
      if (p.test(transcript)) return { kind: "interactive" };
    }
    return null;
  },

  async execute(): Promise<ExecutionResult> {
    const path = join(homedir(), "Desktop", `screenshot-${timestamp()}.png`);
    const result = await runArgv(["screencapture", "-i", path]);
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
      errorCode: "bash_failed",
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
