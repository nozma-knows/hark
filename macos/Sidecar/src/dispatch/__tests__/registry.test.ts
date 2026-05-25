import { describe, expect, test } from "bun:test";
import { buildToolRegistry, findTool } from "../registry.ts";

/**
 * The tool registry is the LLM-visible surface. These tests catch the
 * mistakes that would break that contract:
 *
 *   - Two tools sharing a name → the model can't disambiguate.
 *   - JSON schemas / Zod shapes that disagree → SDK and Messages API
 *     paths route the same transcript to different tools.
 *   - Tool descriptions that are blank / too thin to teach the model
 *     when to pick them.
 *
 * We don't test individual tool execution here — most tools shell out
 * to macOS APIs (`open -a`, `osascript`, etc.) that can't be sensibly
 * unit-tested without a real Mac. The integration smoke test for
 * end-to-end execution lives in the Swift `AgentSidecarTests` suite.
 */

describe("buildToolRegistry", () => {
  test("registers a non-empty set of tools", () => {
    const tools = buildToolRegistry();
    expect(tools.length).toBeGreaterThan(5);
  });

  test("every tool has a unique name", () => {
    const tools = buildToolRegistry();
    const names = tools.map((t) => t.name);
    const unique = new Set(names);
    expect(unique.size).toBe(names.length);
  });

  test("every tool exposes a non-empty description", () => {
    const tools = buildToolRegistry();
    for (const t of tools) {
      expect(t.description.length).toBeGreaterThan(20);
    }
  });

  test("every tool exposes a JSON Schema with object root + properties", () => {
    const tools = buildToolRegistry();
    for (const t of tools) {
      expect(t.inputSchema.type).toBe("object");
      expect(t.inputSchema).toHaveProperty("properties");
    }
  });

  test("every tool exposes a Zod raw shape matching the schema's property set", () => {
    const tools = buildToolRegistry();
    for (const t of tools) {
      const props = Object.keys(
        (t.inputSchema as { properties?: Record<string, unknown> }).properties ?? {}
      );
      const zodKeys = Object.keys(t.zodShape);
      // Same set of keys in both directions — proves the JSON schema
      // and Zod shape describe the same input.
      expect(zodKeys.sort()).toEqual(props.sort());
    }
  });

  test("includes the bash escape hatch", () => {
    const tools = buildToolRegistry();
    expect(findTool(tools, "bash")).not.toBeNull();
  });

  test("includes the core macOS automation tools", () => {
    const tools = buildToolRegistry();
    for (const name of [
      "openApp",
      "openUrl",
      "openInChromeProfile",
      "search",
      "runShortcut",
      "musicControl",
      "screenshot",
      "clipboardCopy",
      "calendarEvent",
      "composeMail",
      "systemToggle",
      "windowControl",
      "runAlias",
    ]) {
      expect(findTool(tools, name)).not.toBeNull();
    }
  });
});

describe("findTool", () => {
  test("returns null for an unknown name", () => {
    const tools = buildToolRegistry();
    expect(findTool(tools, "doesNotExist")).toBeNull();
  });
});

describe("tool input validation", () => {
  test("bash rejects empty input", async () => {
    const tools = buildToolRegistry();
    const bash = findTool(tools, "bash")!;
    const r = await bash.invoke({});
    expect(r.succeeded).toBe(false);
    expect(r.error).toContain("bad_arguments");
  });

  test("openApp rejects missing name", async () => {
    const tools = buildToolRegistry();
    const openApp = findTool(tools, "openApp")!;
    const r = await openApp.invoke({});
    expect(r.succeeded).toBe(false);
    expect(r.error).toContain("bad_arguments");
  });

  test("search rejects unknown service", async () => {
    const tools = buildToolRegistry();
    const search = findTool(tools, "search")!;
    const r = await search.invoke({ service: "askJeeves", query: "x" });
    expect(r.succeeded).toBe(false);
    expect(r.error).toContain("bad_arguments");
  });

  test("musicControl rejects unknown command", async () => {
    const tools = buildToolRegistry();
    const music = findTool(tools, "musicControl")!;
    const r = await music.invoke({ command: "fastForward" });
    expect(r.succeeded).toBe(false);
    expect(r.error).toContain("bad_arguments");
  });
});
