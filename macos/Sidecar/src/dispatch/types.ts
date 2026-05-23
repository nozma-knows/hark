/**
 * Contracts shared by every dispatcher. Each dispatcher lives in
 * its own file under `dispatch/` with a small action type private
 * to that file; the registry erases the action type into a uniform
 * `RegistryEntry` so `tryMatch()` returns a single shape regardless
 * of which dispatcher fired.
 *
 * Splitting `match()` and `execute()` is deliberate: `match()` is
 * pure (no side effects, no I/O) and can be unit-tested with hundreds
 * of transcript variants in milliseconds. `execute()` is the only
 * place that actually touches the system.
 */

export interface Dispatcher<TAction> {
  /** Stable identifier — used in telemetry and the wire `dispatcherId`. */
  readonly id: string;

  /**
   * Lower runs first. Lets more specific dispatchers (e.g. chromeProfile)
   * win over broader ones (e.g. openApp) when both could plausibly match.
   */
  readonly priority: number;

  /**
   * Pure: extracts a structured action from a (normalized) transcript,
   * or returns null if the dispatcher has nothing to say about this one.
   * MUST NOT touch the filesystem, run shell commands, or call APIs —
   * keep it deterministic so tests don't need to mock anything.
   */
  match(transcript: string): TAction | null;

  /**
   * Side-effecting: runs the structured action and returns a result.
   * MUST NOT throw — every failure path maps to `{ succeeded: false, error }`
   * so the caller can render a pill without a try/catch.
   */
  execute(action: TAction): Promise<ExecutionResult>;
}

export interface ExecutionResult {
  /** Human-readable summary shown in the pill. */
  summary: string;
  succeeded: boolean;
  /** Set when `succeeded` is false; surfaced in logs, not the pill. */
  error?: string | undefined;
  /** Every bash command we actually ran on the user's machine. */
  bashCommands: string[];
}

/**
 * Type-erased registry entry. Built by `asEntry(dispatcher)` so each
 * dispatcher's action type stays internal to its file and the
 * registry surface stays free of generics.
 */
export interface RegistryEntry {
  readonly id: string;
  readonly priority: number;
  /**
   * Returns a pre-bound executor that runs the matched action, or null
   * if this dispatcher doesn't handle the transcript. Binding the
   * action into the closure lets `tryMatch` return one shape instead
   * of a `{ dispatcher, action }` tuple the caller has to plumb back.
   */
  tryMatch(transcript: string): (() => Promise<ExecutionResult>) | null;
}

/**
 * Wrap a typed dispatcher into a type-erased registry entry. Captures
 * the action in a closure so `tryMatch` callers don't have to think
 * about the dispatcher's action shape.
 */
export function asEntry<T>(dispatcher: Dispatcher<T>): RegistryEntry {
  return {
    id: dispatcher.id,
    priority: dispatcher.priority,
    tryMatch(transcript) {
      const action = dispatcher.match(transcript);
      if (action === null) return null;
      return () => dispatcher.execute(action);
    },
  };
}
