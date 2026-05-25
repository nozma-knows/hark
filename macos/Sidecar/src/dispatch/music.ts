import { z } from "zod";
import { runArgv } from "../runBash.ts";
import type { ExecutionResult, Tool } from "./types.ts";

/**
 * Music.app transport controls — play, pause, toggle, next, previous,
 * stop. Sticks to the documented AppleScript verbs that have been
 * stable across macOS versions. "Play X" with a query is intentionally
 * NOT handled here — search-and-play is brittle across services
 * (Apple Music vs Spotify vs local library), so it falls back to the
 * `bash` escape hatch or `openUrl` for a specific Apple Music link.
 */

type Command = "play" | "pause" | "toggle" | "next" | "previous" | "stop";

const InputShape = {
  command: z.enum(["play", "pause", "toggle", "next", "previous", "stop"]),
};
const Input = z.object(InputShape);
type Input = z.infer<typeof Input>;

const APPLESCRIPT: Record<Command, string> = {
  play: 'tell application "Music" to play',
  pause: 'tell application "Music" to pause',
  toggle: 'tell application "Music" to playpause',
  next: 'tell application "Music" to next track',
  previous: 'tell application "Music" to previous track',
  stop: 'tell application "Music" to stop',
};

const SUMMARY: Record<Command, string> = {
  play: "Playing music",
  pause: "Paused music",
  toggle: "Toggled music playback",
  next: "Skipped to next track",
  previous: "Skipped to previous track",
  stop: "Stopped music",
};

export const musicControl: Tool<Input> = {
  name: "musicControl",
  description:
    "Control Music.app transport — play/pause/toggle/next/previous/stop. Use this for plain transport commands ('play music', 'pause', 'skip', 'next song'). Does NOT search for a specific song — for that, fall through to bash with an AppleScript that names the track, or use openUrl with an Apple Music share link.",
  inputSchema: {
    type: "object",
    properties: {
      command: {
        type: "string",
        enum: ["play", "pause", "toggle", "next", "previous", "stop"],
        description: "Which transport command to issue.",
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
      summary: `Music.app didn't accept "${command}"`,
      succeeded: false,
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
