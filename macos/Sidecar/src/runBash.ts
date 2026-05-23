/**
 * Single chokepoint for shell execution inside the sidecar. Every
 * dispatcher and the LLM tool loop both route through here so that:
 *
 *   1. A deny-list of dangerous patterns is enforced once, in one place,
 *      with tests — not duplicated across dispatchers.
 *   2. Per-call timeouts can't be forgotten — every caller gets one.
 *   3. The result shape is uniform: dispatchers and the LLM see the same
 *      `BashResult`, so the verification logic upstairs ("did Bash run?
 *      did it exit zero?") doesn't fork by code path.
 *
 * The deny patterns are deliberately narrow — we want to block the
 * obvious foot-guns (rm -rf, sudo, dd if=, formatting drives, piping
 * curl into sh) without making legitimate `open` / `osascript` /
 * `shortcuts run` commands second-guess themselves. Anything not on
 * the list is allowed; we are NOT a sandbox.
 */

export interface BashResult {
  stdout: string;
  stderr: string;
  exitCode: number;
  timedOut: boolean;
  /** Echo back the command we ran so callers can record it for telemetry. */
  command: string;
}

/**
 * Render an argv array as a human-readable shell command — used only
 * for logging / telemetry, never re-exec'd. We single-quote anything
 * that contains a space or shell metacharacter so the rendered string
 * could in principle be pasted into a Terminal and behave the same.
 */
export function renderArgv(argv: ReadonlyArray<string>): string {
  return argv
    .map((arg) => {
      if (/^[a-zA-Z0-9_\-=:.,@/]+$/.test(arg)) return arg;
      return `'${arg.replace(/'/g, `'\\''`)}'`;
    })
    .join(" ");
}

/**
 * Patterns we refuse to run. Each one is a real foot-gun we don't
 * want a voice command (or a hallucinated tool call from an LLM) to
 * trip into accidentally.
 *
 * NOTE: this is a denylist, not a sandbox. macOS itself decides what
 * a process can do — the Hark app isn't sandboxed, so the deny list
 * is about catching obvious mistakes, not enforcing security.
 */
const DENY_PATTERNS: ReadonlyArray<{ pattern: RegExp; reason: string }> = [
  { pattern: /\brm\s+-rf?\b/, reason: "rm -rf is destructive" },
  { pattern: /\bsudo\b/, reason: "sudo escalation refused" },
  { pattern: /\bdd\s+if=/, reason: "dd is destructive" },
  { pattern: /\bmkfs/, reason: "mkfs would format a filesystem" },
  { pattern: /\bdiskutil\s+(erase|secureErase|reformat)/, reason: "diskutil erase refused" },
  { pattern: /\bchmod\s+[0-9]*777\b/, reason: "chmod 777 refused" },
  { pattern: /\bcurl[^|]*\|\s*(sh|bash|zsh)\b/, reason: "curl piped to shell refused" },
  { pattern: /\bwget[^|]*\|\s*(sh|bash|zsh)\b/, reason: "wget piped to shell refused" },
  // Allow `> /dev/null` but block `> /dev/disk*`, `> /dev/sda` etc.
  { pattern: />\s*\/dev\/(?!null|stderr|stdout|tty\b)/, reason: "writing to a /dev/ node refused" },
];

/**
 * Check the command against the deny list. Returns the matching
 * reason if the command should be refused, or null if it's allowed.
 * Pure function — exported for tests.
 */
export function denyReason(command: string): string | null {
  for (const { pattern, reason } of DENY_PATTERNS) {
    if (pattern.test(command)) return reason;
  }
  return null;
}

/**
 * Run a bash command. Never throws — every failure path lands in
 * the returned `BashResult` so callers can render a pill without
 * a try/catch.
 *
 * Timeout: defaults to 10s. The OS-level `open` and `osascript`
 * commands return in milliseconds; anything taking more than 10s
 * is almost certainly hung and we prefer a clean error over a
 * sidecar that wedges on a hanging request.
 */
export async function runBash(
  command: string,
  timeoutMs = 10_000
): Promise<BashResult> {
  const denied = denyReason(command);
  if (denied !== null) {
    return {
      stdout: "",
      stderr: `refused: ${denied}`,
      exitCode: 126,
      timedOut: false,
      command,
    };
  }

  // We always use `bash -lc` so that user-installed CLIs on PATH
  // (Homebrew under /opt/homebrew/bin etc.) resolve as expected.
  // The user's login PATH is the right surface area for voice
  // commands ("open Linear", "shortcuts run …", `pbcopy`).
  const proc = Bun.spawn(["bash", "-lc", command], {
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      proc.kill("SIGTERM");
    } catch {
      // Process may have already exited between the timeout firing
      // and our handler executing — that's fine.
    }
  }, timeoutMs);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);

  return {
    stdout,
    stderr,
    exitCode: typeof exitCode === "number" ? exitCode : 0,
    timedOut,
    command,
  };
}

/**
 * Sibling to `runBash` that spawns a binary directly with an argv array,
 * bypassing the shell. Use this from dispatchers where the executable
 * and its arguments are known at compile time — no shell metacharacter
 * interpretation, no quoting bugs, no deny list needed (dispatchers
 * control the argv shape; only the leaf values come from the user).
 */
export async function runArgv(
  argv: ReadonlyArray<string>,
  timeoutMs = 10_000
): Promise<BashResult> {
  if (argv.length === 0) {
    return {
      stdout: "",
      stderr: "refused: empty argv",
      exitCode: 126,
      timedOut: false,
      command: "",
    };
  }
  const rendered = renderArgv(argv);

  const proc = Bun.spawn([...argv], {
    stdout: "pipe",
    stderr: "pipe",
    stdin: "ignore",
  });

  let timedOut = false;
  const timer = setTimeout(() => {
    timedOut = true;
    try {
      proc.kill("SIGTERM");
    } catch {
      // Already exited.
    }
  }, timeoutMs);

  const [stdout, stderr, exitCode] = await Promise.all([
    new Response(proc.stdout).text(),
    new Response(proc.stderr).text(),
    proc.exited,
  ]);
  clearTimeout(timer);

  return {
    stdout,
    stderr,
    exitCode: typeof exitCode === "number" ? exitCode : 0,
    timedOut,
    command: rendered,
  };
}
