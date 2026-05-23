import { describe, expect, test } from "bun:test";
import { ConversationStore, defaultStore } from "../conversation.ts";

/**
 * Smoke-test for sidecar handlers that route through module-level
 * singletons. Full request/response cycle is covered by the Swift
 * AgentSidecarTests integration suite; here we just confirm the
 * handler bodies — in particular the resetConversation handler —
 * touch the right global state.
 *
 * The handlers themselves live in src/index.ts (the NDJSON loop),
 * which we can't import without spinning up Bun.stdin. So we test
 * the underlying behavior (defaultStore.clear()) instead. This is
 * brittle if someone wires a different store into the handler —
 * a deliberate trade-off, since the index.ts top-level is
 * unimportable from inside the same Bun process.
 */
describe("resetConversation handler semantics", () => {
  test("clearing defaultStore drops all buffered turns", () => {
    defaultStore.record({ transcript: "open linear", summary: "Opened Linear" });
    defaultStore.record({ transcript: "screenshot", summary: "Saved" });
    expect(defaultStore.recentTurns().length).toBe(2);

    defaultStore.clear();
    expect(defaultStore.recentTurns()).toEqual([]);
  });

  test("clear() on a fresh store is a no-op (idempotent)", () => {
    const s = new ConversationStore();
    s.clear();
    expect(s.recentTurns()).toEqual([]);
    s.clear();
    expect(s.recentTurns()).toEqual([]);
  });
});
