/**
 * Rolling buffer of recent voice commands. Both the dispatcher and LLM
 * paths push every completed turn here; the LLM clients pull from it
 * to inject "what we just did" context into the user prompt so the
 * model can resolve follow-ups like "now share that" or "also do X
 * for Linear" against the actual prior action instead of guessing.
 *
 * Why a TTL: stale context is worse than no context. A command an hour
 * ago has nothing to do with what the user is saying now, but if it
 * sits in the buffer the model will dutifully try to relate them.
 * 5 minutes covers a natural "session" of related commands without
 * dragging in unrelated activity.
 *
 * Why a ring cap: even within 5 minutes a user might fire many
 * unrelated commands. Capping at 5 keeps the prompt small (≈400
 * bytes) so prompt-cache hit rate doesn't degrade — only the
 * trailing-edge user message changes, everything before stays
 * cacheable.
 *
 * Lives in its own module so both clients import the SAME singleton
 * `defaultStore` and so tests can construct fresh `ConversationStore`
 * instances without touching the global one.
 */

export interface ConversationTurn {
  /** What the user actually said (post-normalization is fine; we don't care). */
  readonly transcript: string;
  /** The pill summary the user saw — what the agent reported it did. */
  readonly summary: string;
  /** Wall-clock when the turn completed; used for TTL expiry. */
  readonly recordedAt: number;
}

export interface ConversationStoreOpts {
  /** Max turns kept in the buffer. Older turns drop on push. */
  readonly maxTurns?: number;
  /** TTL in ms; turns older than this are filtered out on read. */
  readonly ttlMs?: number;
  /** Test seam: override the wall clock. */
  readonly now?: () => number;
}

export class ConversationStore {
  private readonly maxTurns: number;
  private readonly ttlMs: number;
  private readonly now: () => number;
  private turns: ConversationTurn[] = [];

  constructor(opts: ConversationStoreOpts = {}) {
    this.maxTurns = opts.maxTurns ?? 5;
    this.ttlMs = opts.ttlMs ?? 5 * 60 * 1000;
    this.now = opts.now ?? (() => Date.now());
  }

  /**
   * Append a turn. Drops the oldest entry when the cap is reached so
   * the buffer behaves as a FIFO ring of length `maxTurns`.
   */
  record(turn: Omit<ConversationTurn, "recordedAt">): void {
    const stamped: ConversationTurn = {
      transcript: turn.transcript,
      summary: turn.summary,
      recordedAt: this.now(),
    };
    this.turns.push(stamped);
    if (this.turns.length > this.maxTurns) {
      this.turns.splice(0, this.turns.length - this.maxTurns);
    }
  }

  /**
   * Return turns within the TTL, oldest first. Side-effects: prunes
   * expired entries from the internal buffer so the next call doesn't
   * pay for the filter again.
   */
  recentTurns(): ConversationTurn[] {
    const cutoff = this.now() - this.ttlMs;
    const fresh = this.turns.filter((t) => t.recordedAt >= cutoff);
    if (fresh.length !== this.turns.length) {
      this.turns = fresh;
    }
    return fresh;
  }

  /** Drop everything. Useful between tests and (later) for a manual reset. */
  clear(): void {
    this.turns = [];
  }
}

/**
 * Singleton shared across both AgentClient implementations. Production
 * code reads/writes through this; tests construct their own
 * ConversationStore and pass it explicitly to avoid global coupling.
 */
export const defaultStore = new ConversationStore();

/**
 * Render the recent turns into a human-readable preamble for the
 * LLM's user message. Returns an empty string when there's nothing
 * to show so the prompt stays unchanged on first command of a
 * session — important for prompt-cache hit rate.
 */
export function renderHistoryPreamble(turns: ReadonlyArray<ConversationTurn>): string {
  if (turns.length === 0) return "";
  const lines = turns.map((t) => `- "${t.transcript}" → ${t.summary}`).join("\n");
  return `Recent voice commands in this session (oldest first):\n${lines}\n\n`;
}
