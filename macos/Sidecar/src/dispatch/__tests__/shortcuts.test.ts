import { describe, expect, test } from "bun:test";
import { shortcuts } from "../shortcuts.ts";
import { normalize } from "../normalize.ts";

describe("shortcuts.match", () => {
  test("matches 'run shortcut X'", () => {
    expect(shortcuts.match(normalize("Run shortcut Send to Notion"))?.name).toBe(
      "send to notion"
    );
  });

  test("matches 'run X shortcut'", () => {
    expect(shortcuts.match(normalize("Run Send to Notion shortcut"))?.name).toBe(
      "send to notion"
    );
  });

  test("matches 'run the X shortcut'", () => {
    expect(shortcuts.match(normalize("Run the Send to Notion shortcut"))?.name).toBe(
      "send to notion"
    );
  });

  test("declines plain 'run X' (no 'shortcut' keyword)", () => {
    expect(shortcuts.match(normalize("Run Linear"))).toBeNull();
  });

  test("declines non-run verbs", () => {
    expect(shortcuts.match(normalize("execute send to notion shortcut"))).toBeNull();
  });
});
