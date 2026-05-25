/**
 * Dispatcher → LLM escalation contract.
 *
 * The dispatcher registry is "claim first, execute second": `tryMatch()`
 * picks a dispatcher based on a sync regex test, and only afterward does
 * `execute()` discover whether the action can actually run (the named
 * app might not be installed, the chosen Chrome profile might not exist,
 * etc.). Without escalation, a transcript like "open Notes and take me
 * to a new note" would be greedily eaten by `openApp` (claiming the
 * whole sentence as the app name), `execute()` would fail with
 * "isn't installed", and the user would see a hard error pill instead
 * of the LLM's perfectly capable interpretation of the compound intent.
 *
 * The fix is structured: dispatchers tag *recoverable* failures with
 * an `errorCode` from this module, and `executeCommand` checks
 * `isEscalatable()` before showing the user a failure. Escalatable
 * codes fall through to the LLM with the original transcript;
 * non-escalatable codes (bash exited non-zero on a real command,
 * generic dispatcher failure) are surfaced as-is — Claude can't do
 * better with those.
 *
 * To make a new code escalatable: add it to BOTH the
 * `DispatcherErrorCode` union AND `isEscalatable()`. The exhaustive
 * switch will compile-error on missed cases so escalation stays
 * intentional.
 */

export type DispatcherErrorCode =
  // Escalatable — the dispatcher claimed but the target doesn't exist
  // on this machine. The LLM may interpret the same transcript more
  // flexibly (e.g., compound intent that the dispatcher misread as an
  // app name).
  | "app_not_installed"
  | "profile_not_found"
  // Non-escalatable — the dispatcher delivered the right action, but
  // the action itself failed. Claude can't fix a bash exit code; we
  // surface the failure to the user.
  | "bash_failed"
  | "dispatcher_failed";

/**
 * Is this error recoverable by handing the transcript to the LLM?
 * Exhaustive switch — TypeScript checks every code is classified, so a
 * new code added to the union must be intentionally categorized here.
 */
export function isEscalatable(code: DispatcherErrorCode | undefined): boolean {
  switch (code) {
    case "app_not_installed":
    case "profile_not_found":
      return true;
    case "bash_failed":
    case "dispatcher_failed":
    case undefined:
      return false;
  }
}
