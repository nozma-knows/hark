import { query, type SDKMessage } from "@anthropic-ai/claude-agent-sdk";
import { z } from "zod";

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
 */

export const ExecuteCommandParams = z.object({
  transcript: z.string().min(1),
});
export type ExecuteCommandParams = z.infer<typeof ExecuteCommandParams>;

export interface ExecuteCommandResult {
  summary: string;
  succeeded: boolean;
  usage?: {
    inputTokens: number;
    outputTokens: number;
    cacheReadTokens: number;
    cacheCreationTokens: number;
  };
}

const SYSTEM_PROMPT = `You are a macOS automation agent. The user spoke a voice command — use Bash to execute it on their Mac.

Available Bash tools you should reach for first (they're fast, no GUI required):

- \`open\` — launch apps, open files, open URLs including app schemes:
    open -a Linear
    open linear://issue/ENG-100
    open https://github.com
    open -na "Google Chrome" --args --profile-directory="Default" "https://youtube.com"
    open -na "Google Chrome" --args --profile-directory="Profile 1" "https://github.com"
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
  const { transcript } = ExecuteCommandParams.parse(raw);

  let summary = "";
  let succeeded = false;
  let usage: ExecuteCommandResult["usage"];

  for await (const message of query({
    prompt: `${SYSTEM_PROMPT}\n\nVoice command: ${transcript}`,
    options: {
      maxTurns: 6,
      allowedTools: ["Bash"],
    },
  }) as AsyncIterable<SDKMessage>) {
    if (message.type === "result") {
      const m = message as unknown as {
        subtype?: string;
        result?: string;
        error?: string;
        usage?: Record<string, number>;
      };
      if (m.subtype === "success" && typeof m.result === "string") {
        summary = m.result.trim();
        succeeded = true;
      } else {
        summary = (m.error ?? "Command failed").toString();
        succeeded = false;
      }
      if (m.usage) {
        usage = {
          inputTokens: Number(m.usage.input_tokens ?? 0),
          outputTokens: Number(m.usage.output_tokens ?? 0),
          cacheReadTokens: Number(m.usage.cache_read_input_tokens ?? 0),
          cacheCreationTokens: Number(m.usage.cache_creation_input_tokens ?? 0),
        };
      }
    }
  }

  if (summary.length === 0) {
    summary = "Agent returned no summary";
    succeeded = false;
  }

  return { summary, succeeded, usage };
}
