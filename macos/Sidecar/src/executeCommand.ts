import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";
import { formatChromeProfilesForPrompt, loadChromeProfiles } from "./chromeProfiles.ts";
import { tryMatch } from "./dispatch/index.ts";
import {
  consumeSdkStream,
  type ClaudeUsage,
  type SdkErrorCode,
} from "./sdkStream.ts";

/**
 * Voice command → macOS action. Claude reads the user's spoken request,
 * then drives `Bash` (the only tool we allow) to fulfill it via macOS's
 * built-in command surface:
 *
 *   - `open` and `open -a "App"` / URL schemes (linear://, googlechrome://,
 *     raycast://, etc.) — instant, no scripting needed
 *   - `osascript -e '...'` — AppleScript for app-specific control
 *   - `shortcuts run "Name"` — the user's own Shortcuts library
 *
 * Bash is restricted via `allowedTools` so Claude can't touch files / edit
 * code / use other Claude Code tools in this mode. `maxTurns` caps the
 * agent so a confused interpretation can't loop forever.
 *
 * Reliability: post-stream we VERIFY that Bash actually ran. The Claude
 * Code CLI applies the user's `~/.claude/settings.json` permission rules
 * to every tool call — in a headless sidecar context with `defaultMode:
 * "auto"` and no Bash allow-rule, the auto classifier denies the call,
 * the SDK swallows the denial, and Claude generates "Opened Linear"
 * narratively. We catch this in `consumeSdkStream` so the user sees a
 * real failure instead of a fake-success pill.
 */

export const ExecuteCommandParams = z.object({
  transcript: z.string().min(1),
});
export type ExecuteCommandParams = z.infer<typeof ExecuteCommandParams>;

/**
 * Wire shape Swift decodes. Stays backwards-compatible: existing fields
 * (`summary`, `succeeded`, `usage`) keep their meaning; new fields are
 * additive and `JSONDecoder` on the Swift side ignores unknown keys, so
 * old releases of Hark keep working with this shape.
 */
export interface ExecuteCommandResult {
  summary: string;
  succeeded: boolean;
  /** Which code path produced this result — for telemetry + debugging.
   *  "dispatcher" — deterministic match, no LLM involved (fast path).
   *  "llm-sdk"    — fell through to the Claude Agent SDK. */
  route: "dispatcher" | "llm-sdk";
  /** Stable id of the dispatcher that fired, when `route === "dispatcher"`. */
  dispatcherId?: string | undefined;
  /** Every Bash command the agent actually executed, in order. */
  bashCommands: string[];
  /** Assistant turns observed (one per assistant message in the stream).
   *  Zero when the dispatcher path handled the command without invoking
   *  the LLM at all. */
  llmTurns: number;
  /** Total wall-clock for the whole command. */
  latencyMs: number;
  /** Disambiguates which failure path fired when `succeeded` is false. */
  errorCode?: ExecuteCommandErrorCode | undefined;
  usage?: ClaudeUsage | undefined;
}

/** Union of every failure mode either route can produce. */
export type ExecuteCommandErrorCode = SdkErrorCode | "dispatcher_failed";

const SYSTEM_PROMPT = `You are a macOS automation agent. The user spoke a voice command — use Bash to execute it on their Mac.

Available Bash tools you should reach for first (they're fast, no GUI required):

- \`open\` — launch apps, open files, open URLs including app schemes:
    open -a Linear
    open linear://issue/ENG-100
    open https://github.com
    open -na "Google Chrome" --args --profile-directory="Default" "https://youtube.com"
    open -na "Google Chrome" --args --profile-directory="Profile 1" "https://github.com"
  When the user names a Chrome profile (e.g. "my personal profile", "work
  profile"), look up the matching --profile-directory in the profile
  table below — never guess "Default" or "Profile 1" blindly.
- \`osascript -e '...'\` — AppleScript for in-app control (Chrome, Safari, Mail, Notes, Music, Finder, etc.). Examples:
    osascript -e 'tell application "Music" to play'
    osascript -e 'tell application "Safari" to make new document with properties {URL:"https://example.com"}'
    osascript -e 'tell application "System Events" to keystroke "n" using {command down}'
- \`shortcuts run "Name"\` — run one of the user's macOS Shortcuts
- \`screencapture\`, \`pbcopy\`, \`pbpaste\`, etc. — standard macOS CLIs

Examples of voice command → action:
- "Open Linear" → open -a Linear
- "Open Linear ticket ENG-100" → open linear://issue/ENG-100
- "Open Chrome with my personal profile and go to YouTube" → open -na "Google Chrome" --args --profile-directory="Default" "https://youtube.com"
- "Play music" → open -a Music && osascript -e 'tell application "Music" to play'
- "Take a screenshot" → screencapture -i ~/Desktop/screenshot.png
- "Copy github.com to my clipboard" → echo "https://github.com" | pbcopy

Rules:
- Just do what the user asked. Don't ask clarifying questions.
- Use reasonable defaults when ambiguous (e.g. "Chrome" → "Google Chrome", "Linear" → the Linear.app).
- NEVER run destructive commands (\`rm -rf\`, \`sudo\`, formatting drives, killing arbitrary processes) unless the user clearly asked for them.
- After the action succeeds, respond with one short sentence describing exactly what you did. No preamble, no markdown.
- If the command genuinely can't be executed (e.g. app not installed), say so in one short sentence.`;

export async function executeCommand(raw: unknown): Promise<ExecuteCommandResult> {
  const start = Date.now();
  const { transcript } = ExecuteCommandParams.parse(raw);

  // 1. Dispatcher path: deterministic match on the most common voice
  //    commands ("open Linear", "take a screenshot", …). Skips the LLM
  //    entirely on the happy path — fast (~tens of ms), free, immune
  //    to the user's Claude Code settings.json permission state.
  const matched = tryMatch(transcript);
  if (matched !== null) {
    const result = await matched.execute();
    return {
      summary: result.summary,
      succeeded: result.succeeded,
      route: "dispatcher",
      dispatcherId: matched.id,
      bashCommands: result.bashCommands,
      llmTurns: 0,
      latencyMs: Date.now() - start,
      ...(result.error ? { errorCode: "dispatcher_failed" as const } : {}),
    };
  }

  // 2. LLM fallback for anything the dispatchers don't handle. Pre-load
  //    Chrome's profile name → directory mapping so Claude can map
  //    "my personal profile" / "work profile" to the right
  //    --profile-directory flag without guessing. Empty string when
  //    Chrome isn't installed.
  const chromeProfilesSection = formatChromeProfilesForPrompt(
    await loadChromeProfiles()
  );

  // Tell the SDK where the user's locally-installed claude binary lives
  // (we don't bundle the SDK's optional 200 MB native binary in the
  // bun-compiled sidecar). HARK_CLAUDE_BINARY is set by ClaudeAuth.
  const claudeBinary = process.env.HARK_CLAUDE_BINARY;

  const systemPrompt = `${SYSTEM_PROMPT}${chromeProfilesSection}`;

  const stream = query({
    prompt: `${systemPrompt}\n\nVoice command: ${transcript}`,
    options: {
      maxTurns: 6,
      allowedTools: ["Bash"],
      ...(claudeBinary ? { pathToClaudeCodeExecutable: claudeBinary } : {}),
    },
  }) as AsyncIterable<SDKMessage>;

  const result = await consumeSdkStream(stream);

  return {
    summary: result.summary,
    succeeded: result.succeeded,
    route: "llm-sdk",
    bashCommands: result.bashCommands,
    llmTurns: result.llmTurns,
    latencyMs: Date.now() - start,
    ...(result.errorCode ? { errorCode: result.errorCode } : {}),
    ...(result.usage ? { usage: result.usage } : {}),
  };
}
