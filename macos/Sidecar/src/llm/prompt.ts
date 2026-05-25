/**
 * Single source of truth for the system prompt the LLM clients use.
 * Both transports (MessagesClient over Anthropic Messages API,
 * SdkClient over Claude Agent SDK) pass the same prompt — keeps the
 * two implementations honest about being two routes to the same
 * behaviour.
 *
 * The prompt is intentionally short. The tool definitions themselves
 * carry the detailed routing guidance ("when to pick openApp vs
 * openInChromeProfile vs bash") via each tool's `description`; the
 * prompt only needs to set the persona, lay out the dynamic context
 * (Chrome profiles, alias phrases on this Mac) that the tools can't
 * embed inside themselves, and remind the model to actually call a
 * tool instead of narrating.
 *
 * The static part is the ideal prompt-cache anchor: identical across
 * every voice command on the same Mac. The dynamic part (profile +
 * alias list) is appended at the end — it changes when the user
 * adds an alias or installs Chrome, but it's stable across the
 * timescale of a voice command, so it still caches well per machine.
 */

import { formatChromeProfilesForPrompt, loadChromeProfiles } from "../chromeProfiles.ts";
import { defaultAliasStore } from "../dispatch/aliasStore.ts";
import type { ToolEntry } from "../dispatch/types.ts";

const STATIC_PROMPT = `You are a macOS voice-control agent. The user spoke a voice command — pick exactly one of the structured tools below and call it with the right arguments to fulfil their request.

Routing principles:
- Read the WHOLE sentence before picking a tool. "Open Linear" → openApp. "Open Linear in my work profile" → openInChromeProfile. "Open a Juggle task to fix the pill bug" → the user's intent is to CREATE a task, not literally open the Juggle app, so prefer a tool that creates a task (or fall through to bash if no structured tool covers it).
- The structured tools (openApp, openUrl, openInChromeProfile, search, runShortcut, musicControl, screenshot, clipboardCopy, calendarEvent, composeMail, systemToggle, windowControl, runAlias) are FAST and EXACT. Always prefer them when one fits.
- \`bash\` is the escape hatch. Use it when no structured tool covers the request, OR when the user's request needs a compound shell command. Prefer one bash call that expresses the compound intent over chaining multiple tool calls.
- When the user names a Chrome profile, route through openInChromeProfile — never plain openApp or openUrl.
- For searches inside a web app (Gmail, Linear, GitHub, etc.), prefer the \`search\` tool when the service is on its known list; otherwise compose the search URL yourself and call openUrl with it.
- runAlias is for the user's custom commands. Their available alias phrases (if any) are listed below; only call runAlias when the user's transcript matches one of those phrases.

Output rules:
- Just do what the user asked. Don't ask clarifying questions.
- Use reasonable defaults when ambiguous (e.g. "Chrome" → "Google Chrome", "Linear" → the Linear.app).
- NEVER call destructive bash (\`rm -rf\`, \`sudo\`, formatting drives, killing arbitrary processes) unless the user clearly asked for them.
- After the tool returns, respond with one short sentence describing exactly what you did. No preamble, no markdown.
- If the tool reports failure, briefly say why in one sentence — don't pretend it succeeded.`;

/**
 * Compose the full system prompt. Tool descriptions are NOT embedded
 * here — the Messages API gets them as `tools` on the request, and the
 * Agent SDK gets them via the MCP server. Including them here would
 * just be redundant tokens for the model to read.
 *
 * The `registry` parameter is currently unused in the rendered prompt
 * — it's plumbed through so future per-tool dynamic context (e.g.
 * "current openApp catalog has these apps installed") can attach to a
 * specific tool without a prompt rewrite.
 */
export async function buildSystemPrompt(_registry?: ToolEntry[]): Promise<string> {
  const profilesSection = formatChromeProfilesForPrompt(await loadChromeProfiles());
  const aliasSection = formatAliasesForPrompt();
  return `${STATIC_PROMPT}${profilesSection}${aliasSection}`;
}

/**
 * List the user's alias phrases so the model knows which transcripts
 * map to the runAlias tool. We deliberately don't expose the bash
 * commands behind each phrase — keeps the prompt small and stops the
 * model from "helpfully" doing what the alias does via bash without
 * going through the runAlias tool (which would skip telemetry).
 */
function formatAliasesForPrompt(): string {
  const aliases = defaultAliasStore.current();
  if (aliases.length === 0) return "";
  const lines = aliases.map((a) => `  - "${a.phrase}"`).join("\n");
  return `\nUser-defined alias phrases (call runAlias when the transcript matches one of these):\n${lines}\n`;
}
