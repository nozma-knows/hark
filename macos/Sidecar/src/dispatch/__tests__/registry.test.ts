import { describe, expect, test } from "bun:test";
import { tryMatch, _entriesForTests } from "../index.ts";

/**
 * Registry-level tests — pin down the priority order and confirm that
 * the right dispatcher claims each canonical command shape.
 */
describe("dispatch registry", () => {
  test("priorities are sorted ascending (specific first)", () => {
    const priorities = _entriesForTests.map((e) => e.priority);
    const sorted = [...priorities].sort((a, b) => a - b);
    expect(priorities).toEqual(sorted);
  });

  test("chrome-profile claims 'open X in Y profile'", () => {
    expect(tryMatch("Open youtube.com in my work profile")?.id).toBe("chrome-profile");
  });

  test("open-url claims '<verb> <domain>'", () => {
    expect(tryMatch("Open github.com")?.id).toBe("open-url");
    expect(tryMatch("Go to news.ycombinator.com")?.id).toBe("open-url");
  });

  test("shortcuts claims 'run X shortcut'", () => {
    expect(tryMatch("Run shortcut Daily Briefing")?.id).toBe("shortcuts");
  });

  test("open-app claims '<verb> <app>'", () => {
    expect(tryMatch("Open Linear")?.id).toBe("open-app");
    expect(tryMatch("Launch Chrome")?.id).toBe("open-app");
  });

  test("screencapture claims 'take a screenshot'", () => {
    expect(tryMatch("Take a screenshot")?.id).toBe("screencapture");
    expect(tryMatch("Screenshot.")?.id).toBe("screencapture");
  });

  test("clipboard claims 'copy X to clipboard'", () => {
    expect(tryMatch("Copy github.com to my clipboard")?.id).toBe("clipboard");
  });

  test("returns null for unhandled transcripts", () => {
    expect(tryMatch("Compose an email about Friday's incident")).toBeNull();
    expect(tryMatch("What time is it in Tokyo")).toBeNull();
    expect(tryMatch("Summarize my screen")).toBeNull();
  });
});
