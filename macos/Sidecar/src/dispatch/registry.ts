import { defaultAliasStore, type AliasStore } from "./aliasStore.ts";
import { bash } from "./bash.ts";
import { calendarEvent } from "./calendar.ts";
import { openInChromeProfile } from "./chromeProfile.ts";
import { clipboardCopy } from "./clipboard.ts";
import { composeMail } from "./mail.ts";
import { musicControl } from "./music.ts";
import { openApp } from "./openApp.ts";
import { openUrl } from "./openUrl.ts";
import { makeRunAlias } from "./alias.ts";
import { runShortcut } from "./shortcuts.ts";
import { screenshot } from "./screencapture.ts";
import { search } from "./search.ts";
import { systemToggle } from "./systemToggle.ts";
import { asEntry, type ToolEntry } from "./types.ts";
export type { ToolEntry } from "./types.ts";
import { windowControl } from "./window.ts";

/**
 * Build the tool registry used by both LLM transports (Messages API
 * via MessagesClient, Agent SDK via createSdkMcpServer). The registry
 * is the single source of truth for which tools the model can pick;
 * the LLM is the router, so the order here is purely for readability.
 *
 * Built per-call (not a module-level singleton) so a `bash` deny-list
 * change or an `AliasStore` swap takes effect on the next request
 * instead of needing a sidecar restart.
 */

export interface BuildRegistryOpts {
  /** Test seam — defaults to the on-disk alias store singleton. */
  aliasStore?: AliasStore;
}

export function buildToolRegistry(opts: BuildRegistryOpts = {}): ToolEntry[] {
  const runAlias = makeRunAlias(opts.aliasStore ?? defaultAliasStore);
  return [
    asEntry(openApp),
    asEntry(openUrl),
    asEntry(openInChromeProfile),
    asEntry(search),
    asEntry(runShortcut),
    asEntry(musicControl),
    asEntry(screenshot),
    asEntry(clipboardCopy),
    asEntry(calendarEvent),
    asEntry(composeMail),
    asEntry(systemToggle),
    asEntry(windowControl),
    asEntry(runAlias),
    // bash LAST so the model reads it as the fallback option after the
    // structured tools above. Listing order doesn't affect the model's
    // ability to pick it, but it does affect which tool a reader sees
    // first when scanning the system prompt.
    asEntry(bash),
  ];
}

/** Look up a tool entry by name. Returns null if no tool matches —
 *  the loop will surface this to the model as an `is_error` result. */
export function findTool(registry: ToolEntry[], name: string): ToolEntry | null {
  return registry.find((t) => t.name === name) ?? null;
}
