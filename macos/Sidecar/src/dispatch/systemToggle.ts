import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * System toggles — Do Not Disturb / Focus, dark mode, volume controls,
 * mute. Each action has a single stable AppleScript surface that has
 * worked unchanged across the last several macOS versions. Stuff that's
 * brittle across versions (system-wide tiling, true "snap" behavior)
 * lives outside this tool.
 */

type Command =
  | "dndOn"
  | "dndOff"
  | "darkMode"
  | "lightMode"
  | "volumeUp"
  | "volumeDown"
  | "volumeSet"
  | "mute"
  | "unmute";

const InputShape = {
  command: z.enum([
    "dndOn",
    "dndOff",
    "darkMode",
    "lightMode",
    "volumeUp",
    "volumeDown",
    "volumeSet",
    "mute",
    "unmute",
  ]),
  value: z.number().int().min(0).max(100).optional(),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

const VOLUME_STEP = 10;

function clamp(n: number, lo: number, hi: number): number {
  return Math.max(lo, Math.min(hi, n));
}

function buildAppleScript(action: Input): string {
  switch (action.command) {
    case "dndOn":
    case "dndOff":
      return [
        `tell application "Shortcuts Events"`,
        `  try`,
        `    run shortcut "${action.command === "dndOn" ? "Turn On Do Not Disturb" : "Turn Off Do Not Disturb"}"`,
        `  on error`,
        `    tell application "System Events"`,
        `      tell process "ControlCenter"`,
        `        try`,
        `          click menu bar item "Focus" of menu bar 1`,
        `        end try`,
        `      end tell`,
        `    end tell`,
        `  end try`,
        `end tell`,
      ].join("\n");

    case "darkMode":
    case "lightMode":
      return [
        `tell application "System Events"`,
        `  tell appearance preferences`,
        `    set dark mode to ${action.command === "darkMode" ? "true" : "false"}`,
        `  end tell`,
        `end tell`,
      ].join("\n");

    case "volumeUp":
      return [
        `set vol to output volume of (get volume settings)`,
        `set vol to vol + ${VOLUME_STEP}`,
        `if vol > 100 then set vol to 100`,
        `set volume output volume vol`,
      ].join("\n");

    case "volumeDown":
      return [
        `set vol to output volume of (get volume settings)`,
        `set vol to vol - ${VOLUME_STEP}`,
        `if vol < 0 then set vol to 0`,
        `set volume output volume vol`,
      ].join("\n");

    case "volumeSet":
      return `set volume output volume ${clamp(action.value ?? 0, 0, 100)}`;

    case "mute":
      return `set volume with output muted`;

    case "unmute":
      return `set volume without output muted`;
  }
}

const SUMMARY: Record<Command, string> = {
  dndOn: "Do Not Disturb on",
  dndOff: "Do Not Disturb off",
  darkMode: "Switched to dark mode",
  lightMode: "Switched to light mode",
  volumeUp: "Turned volume up",
  volumeDown: "Turned volume down",
  volumeSet: "Set volume",
  mute: "Muted",
  unmute: "Unmuted",
};

export const systemToggle: Tool<Input> = {
  name: "systemToggle",
  description:
    "Toggle system-level settings: Do Not Disturb / Focus (dndOn/dndOff), appearance (darkMode/lightMode), audio volume (volumeUp/volumeDown by 10%, volumeSet with value 0–100), mute/unmute. Pass `value` only with command='volumeSet'.",
  inputSchema: {
    type: "object",
    properties: {
      command: {
        type: "string",
        enum: [
          "dndOn",
          "dndOff",
          "darkMode",
          "lightMode",
          "volumeUp",
          "volumeDown",
          "volumeSet",
          "mute",
          "unmute",
        ],
        description: "Which toggle to apply.",
      },
      value: {
        type: "integer",
        minimum: 0,
        maximum: 100,
        description:
          "Required only when command='volumeSet'. Absolute volume 0–100.",
      },
    },
    required: ["command"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute(action): Promise<ExecutionResult> {
    const script = buildAppleScript(action);
    const result = await runArgv(["osascript", "-e", script]);
    const summary =
      action.command === "volumeSet" && action.value !== undefined
        ? `Set volume to ${action.value}`
        : SUMMARY[action.command];
    if (result.exitCode === 0) {
      return {
        summary,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't apply "${action.command}"`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
