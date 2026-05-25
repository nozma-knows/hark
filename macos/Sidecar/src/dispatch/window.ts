import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Window management for the frontmost window — fullscreen toggle,
 * minimize, hide, close. Driven by AppleScript's System Events
 * surface, which is uniform across well-behaved Cocoa apps. We stay
 * narrow on purpose: no tiling shortcuts ("snap left") because tiling
 * behavior differs across macOS versions.
 */

type Command = "fullscreen" | "exitFullscreen" | "minimize" | "hide" | "close";

const InputShape = {
  command: z.enum(["fullscreen", "exitFullscreen", "minimize", "hide", "close"]),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

const APPLESCRIPT: Record<Command, string> = {
  fullscreen: [
    `tell application "System Events"`,
    `  set frontApp to first process whose frontmost is true`,
    `  set frontAppName to name of frontApp`,
    `end tell`,
    `tell application frontAppName to activate`,
    `tell application "System Events" to key code 3 using {control down, command down}`,
  ].join("\n"),

  exitFullscreen: [
    `tell application "System Events" to key code 3 using {control down, command down}`,
  ].join("\n"),

  minimize: [
    `tell application "System Events"`,
    `  set frontApp to first process whose frontmost is true`,
    `  try`,
    `    set value of attribute "AXMinimized" of window 1 of frontApp to true`,
    `  end try`,
    `end tell`,
  ].join("\n"),

  hide: [
    `tell application "System Events"`,
    `  set frontApp to first process whose frontmost is true`,
    `  set visible of frontApp to false`,
    `end tell`,
  ].join("\n"),

  close: [
    `tell application "System Events" to keystroke "w" using {command down}`,
  ].join("\n"),
};

const SUMMARY: Record<Command, string> = {
  fullscreen: "Toggled fullscreen",
  exitFullscreen: "Exited fullscreen",
  minimize: "Minimized window",
  hide: "Hid app",
  close: "Closed window",
};

export const windowControl: Tool<Input> = {
  name: "windowControl",
  description:
    "Control the frontmost window: fullscreen (enter), exitFullscreen, minimize (to Dock), hide (entire app via Cmd+H), close (current window via Cmd+W). Does NOT close the entire app — for that, the user wants 'quit' which isn't covered yet (fall back to bash with osascript).",
  inputSchema: {
    type: "object",
    properties: {
      command: {
        type: "string",
        enum: ["fullscreen", "exitFullscreen", "minimize", "hide", "close"],
        description: "Which window action to perform on the frontmost window.",
      },
    },
    required: ["command"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ command }): Promise<ExecutionResult> {
    const result = await runArgv(["osascript", "-e", APPLESCRIPT[command]]);
    if (result.exitCode === 0) {
      return {
        summary: SUMMARY[command],
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: `Couldn't ${command} window`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
