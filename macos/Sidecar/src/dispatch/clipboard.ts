import type { Dispatcher, ExecutionResult } from "./types.ts";

/**
 * "Copy github.com to my clipboard" / "Put hello world on the clipboard"
 * — pipes a literal string to pbcopy.
 *
 * We DON'T use `runArgv` here because pbcopy reads from stdin, which
 * the existing helpers don't support. Spawning directly with a stdin
 * pipe is ~10 lines and keeps the dispatcher self-contained.
 *
 * Priority 40 — runs after the more-specific dispatchers.
 */

interface ClipboardAction {
  readonly text: string;
}

const PATTERNS: ReadonlyArray<RegExp> = [
  /^copy\s+(.+?)\s+to\s+(?:my\s+|the\s+)?clipboard\s*$/,
  /^put\s+(.+?)\s+(?:on|in)\s+(?:my\s+|the\s+)?clipboard\s*$/,
];

export const clipboard: Dispatcher<ClipboardAction> = {
  id: "clipboard",
  priority: 40,

  match(transcript) {
    for (const p of PATTERNS) {
      const m = transcript.match(p);
      if (m?.[1]) return { text: m[1].trim() };
    }
    return null;
  },

  async execute({ text }): Promise<ExecutionResult> {
    const proc = Bun.spawn(["pbcopy"], {
      stdout: "pipe",
      stderr: "pipe",
      stdin: "pipe",
    });
    proc.stdin.write(text);
    await proc.stdin.end();
    const exitCode = await proc.exited;
    const stderr = await new Response(proc.stderr).text();
    const command = `printf %s '<text>' | pbcopy`;
    if (exitCode === 0) {
      return {
        summary: `Copied "${truncate(text, 40)}" to clipboard`,
        succeeded: true,
        bashCommands: [command],
      };
    }
    return {
      summary: "Couldn't copy to clipboard",
      succeeded: false,
      error: stderr.trim() || `exit ${exitCode}`,
      bashCommands: [command],
    };
  },
};

function truncate(s: string, n: number): string {
  return s.length > n ? `${s.slice(0, n - 1)}…` : s;
}
