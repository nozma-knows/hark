import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Draft a Calendar.app event with the given title. The event is
 * scheduled for "now + 1 hour" as a default and Calendar opens
 * focused on it so the user can adjust the time. Parsing
 * natural-language dates ("tomorrow at 3pm") is left to the LLM —
 * the model can pass a parsed start/end as ISO strings if it wants
 * to be precise (future enhancement).
 */

const InputShape = {
  title: z.string().min(1, "title is required"),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

export const calendarEvent: Tool<Input> = {
  name: "calendarEvent",
  description:
    "Draft a new event in Calendar.app. The event is scheduled for one hour from now and Calendar opens focused on it so the user can adjust the time. Use this for 'schedule a meeting called X', 'add an event for X', 'put X on my calendar'. For natural-language times, just include them in the title — the user can correct in Calendar's UI.",
  inputSchema: {
    type: "object",
    properties: {
      title: {
        type: "string",
        description: "The event title.",
      },
    },
    required: ["title"],
  },
  zodShape: InputShape,

  parseInput(raw) {
    return Input.parse(raw);
  },

  async execute({ title }): Promise<ExecutionResult> {
    const script = buildAppleScript(title);
    const result = await runArgv(["osascript", "-e", script]);
    if (result.exitCode === 0) {
      return {
        summary: `Drafted "${truncate(title, 40)}" in Calendar`,
        succeeded: true,
        bashCommands: [result.command],
      };
    }
    return {
      summary: "Calendar didn't accept the event",
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};

function buildAppleScript(title: string): string {
  const escaped = escapeAppleScript(title);
  return [
    `set startTime to (current date) + (60 * 60)`,
    `set endTime to startTime + (60 * 60)`,
    `tell application "Calendar"`,
    `  tell calendar 1`,
    `    set newEvent to make new event with properties {summary:"${escaped}", start date:startTime, end date:endTime}`,
    `    show newEvent`,
    `  end tell`,
    `  activate`,
    `end tell`,
  ].join("\n");
}

export function escapeAppleScript(s: string): string {
  return s.replace(/\\/g, "\\\\").replace(/"/g, '\\"');
}

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}
