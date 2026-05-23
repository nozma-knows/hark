import { runArgv } from "../runBash.ts";
import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * Music.app transport controls — play, pause, next, previous, stop.
 * Originally deferred from the dispatcher set because AppleScript
 * dialects across Music.app versions had been brittle, but the
 * commands here are the documented stable surface (Music has
 * supported these since iTunes 4) and they're a high-volume voice
 * command shape that doesn't deserve an LLM round-trip.
 *
 * Priority 35 — runs after open-app (so "open Music" still routes to
 * launch-the-app rather than send-play-command-to-nothing). Inside
 * the music dispatcher we explicitly send `osascript` to Music; if
 * Music isn't running, AppleScript launches it as a side effect.
 *
 * "Play X" with a query is intentionally NOT handled here — that's
 * search-and-play, which is brittle across services (Apple Music vs
 * Spotify vs local library). Sticks to transport: fewer surprises.
 */

type Command = "play" | "pause" | "toggle" | "next" | "previous" | "stop";

interface MusicAction {
  readonly command: Command;
}

/** Map normalized transcript patterns to the AppleScript command. */
const PATTERNS: ReadonlyArray<{ pattern: RegExp; command: Command }> = [
  { pattern: /^(?:play|resume|start)\s+(?:the\s+)?music$/, command: "play" },
  { pattern: /^play$/, command: "play" },
  { pattern: /^pause(?:\s+(?:the\s+)?music)?$/, command: "pause" },
  { pattern: /^stop(?:\s+(?:the\s+)?music)?$/, command: "stop" },
  { pattern: /^(?:next|skip)(?:\s+(?:song|track))?$/, command: "next" },
  { pattern: /^(?:previous|back|prev)(?:\s+(?:song|track))?$/, command: "previous" },
  { pattern: /^(?:toggle\s+)?(?:play\s*\/\s*pause|play\s+pause|playpause)$/, command: "toggle" },
];

/** AppleScript snippets per command. `playpause` is Music.app's official
 *  toggle verb; `next track` / `previous track` are the canonical skip
 *  forms that work whether or not Music is currently playing. */
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

export const music: Dispatcher<MusicAction> = {
  id: "music",
  priority: 35,

  match(transcript) {
    for (const { pattern, command } of PATTERNS) {
      if (pattern.test(transcript)) return { command };
    }
    return null;
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
      errorCode: "bash_failed",
      error: result.stderr.trim() || `exit ${result.exitCode}`,
      bashCommands: [result.command],
    };
  },
};
