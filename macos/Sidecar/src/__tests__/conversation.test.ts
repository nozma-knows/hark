import { describe, expect, test } from "bun:test";
import {
  ConversationStore,
  renderHistoryPreamble,
  type ConversationTurn,
} from "../conversation.ts";

/**
 * The conversation buffer is small and pure — the tests pin down the
 * three behaviors that actually matter: FIFO ring cap, TTL pruning,
 * and the preamble's "empty → no output" contract (which keeps the
 * prompt cache hot for the first command of a session).
 */

describe("ConversationStore", () => {
  test("recentTurns is empty on a fresh store", () => {
    const s = new ConversationStore();
    expect(s.recentTurns()).toEqual([]);
  });

  test("record + recentTurns round-trip with timestamp stamped", () => {
    let t = 1000;
    const s = new ConversationStore({ now: () => t });
    s.record({ transcript: "open linear", summary: "Opened Linear" });
    t = 1500;
    s.record({ transcript: "screenshot", summary: "Saved to Desktop" });
    const turns = s.recentTurns();
    expect(turns).toHaveLength(2);
    expect(turns[0]?.transcript).toBe("open linear");
    expect(turns[0]?.recordedAt).toBe(1000);
    expect(turns[1]?.transcript).toBe("screenshot");
    expect(turns[1]?.recordedAt).toBe(1500);
  });

  test("FIFO ring drops oldest when over capacity", () => {
    let t = 0;
    const s = new ConversationStore({ maxTurns: 3, now: () => t });
    for (let i = 0; i < 5; i++) {
      t = i * 100;
      s.record({ transcript: `cmd-${i}`, summary: `out-${i}` });
    }
    const turns = s.recentTurns();
    expect(turns.map((x) => x.transcript)).toEqual(["cmd-2", "cmd-3", "cmd-4"]);
  });

  test("TTL prunes expired turns", () => {
    let t = 0;
    const s = new ConversationStore({ ttlMs: 1000, now: () => t });
    s.record({ transcript: "old", summary: "stale" });
    t = 500;
    s.record({ transcript: "still fresh", summary: "" });
    t = 1500; // 'old' is 1500ms old, beyond TTL; 'still fresh' is 1000ms — at boundary
    const turns = s.recentTurns();
    expect(turns.map((x) => x.transcript)).toEqual(["still fresh"]);
  });

  test("TTL boundary is inclusive: exactly-at-cutoff turn is kept", () => {
    let t = 0;
    const s = new ConversationStore({ ttlMs: 1000, now: () => t });
    s.record({ transcript: "boundary", summary: "" });
    t = 1000; // boundary turn is exactly 1000ms old
    expect(s.recentTurns().map((x) => x.transcript)).toEqual(["boundary"]);
  });

  test("clear empties the buffer", () => {
    const s = new ConversationStore();
    s.record({ transcript: "a", summary: "b" });
    s.clear();
    expect(s.recentTurns()).toEqual([]);
  });

  test("expired turns are pruned in-place — no leak across calls", () => {
    let t = 0;
    const s = new ConversationStore({ ttlMs: 100, now: () => t });
    for (let i = 0; i < 10; i++) {
      t = i * 50;
      s.record({ transcript: `cmd-${i}`, summary: "" });
    }
    t = 10_000;
    // First call prunes; second call should see the same empty result
    // without re-filtering a long list.
    expect(s.recentTurns()).toEqual([]);
    expect(s.recentTurns()).toEqual([]);
  });
});

describe("renderHistoryPreamble", () => {
  test("empty turns → empty string (preserves prompt-cache hit)", () => {
    expect(renderHistoryPreamble([])).toBe("");
  });

  test("formats a single turn", () => {
    const turn: ConversationTurn = {
      transcript: "open Linear",
      summary: "Opened Linear",
      recordedAt: 0,
    };
    expect(renderHistoryPreamble([turn])).toBe(
      'Recent voice commands in this session (oldest first):\n- "open Linear" → Opened Linear\n\n'
    );
  });

  test("formats multiple turns oldest-first with trailing blank line", () => {
    const turns: ConversationTurn[] = [
      { transcript: "open Linear", summary: "Opened Linear", recordedAt: 0 },
      { transcript: "take screenshot", summary: "Saved to Desktop", recordedAt: 100 },
    ];
    const out = renderHistoryPreamble(turns);
    expect(out).toContain('"open Linear"');
    expect(out).toContain('"take screenshot"');
    // Trailing \n\n separates preamble from the user prompt cleanly.
    expect(out.endsWith("\n\n")).toBe(true);
  });
});
