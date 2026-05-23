import { describe, expect, test } from "bun:test";
import { openApp } from "../openApp.ts";
import { normalize } from "../normalize.ts";

/**
 * `match()` is the only thing tested in unit tests — `execute()` touches
 * the filesystem catalog + spawns `open`, which is integration territory.
 * The contract we pin down here: which transcripts the dispatcher claims
 * and which it doesn't, and what canonical name it extracts.
 */
describe("openApp.match", () => {
  test("matches 'open Linear' to Linear (aliased)", () => {
    const a = openApp.match(normalize("Open Linear"));
    expect(a?.canonical).toBe("Linear");
  });

  test("matches 'launch chrome' to Google Chrome (alias)", () => {
    expect(openApp.match(normalize("Launch chrome"))?.canonical).toBe("Google Chrome");
  });

  test("matches 'start vscode' to Visual Studio Code (alias)", () => {
    expect(openApp.match(normalize("Start vscode"))?.canonical).toBe("Visual Studio Code");
  });

  test("matches 'open Linear app' with redundant trailing 'app'", () => {
    expect(openApp.match(normalize("Open Linear app"))?.canonical).toBe("Linear");
  });

  test("title-cases unknown names (best guess)", () => {
    expect(openApp.match(normalize("Open foobar"))?.canonical).toBe("Foobar");
  });

  test("does NOT claim URL-shaped transcripts", () => {
    expect(openApp.match(normalize("Open youtube.com"))).toBeNull();
    expect(openApp.match(normalize("Open github.com"))).toBeNull();
  });

  test("does NOT claim 'open X in Y profile' (chromeProfile owns it)", () => {
    expect(openApp.match(normalize("Open YouTube in my work profile"))).toBeNull();
  });

  test("declines transcripts that aren't 'open/launch/start'", () => {
    expect(openApp.match(normalize("close linear"))).toBeNull();
    expect(openApp.match(normalize("what time is it"))).toBeNull();
    expect(openApp.match(normalize(""))).toBeNull();
  });

  test("handles trailing whitespace / Whisper artifacts via normalize", () => {
    // Caller normalizes; this confirms the regex doesn't trip on the
    // already-normalized output.
    expect(openApp.match(normalize("Open Linear."))?.canonical).toBe("Linear");
    expect(openApp.match(normalize("  open   linear  "))?.canonical).toBe("Linear");
  });

  // MARK: - Filler word + compound verb variations

  test("'open up X' strips the 'up' filler", () => {
    expect(openApp.match(normalize("Open up Linear"))?.canonical).toBe("Linear");
    expect(openApp.match(normalize("open up chrome"))?.canonical).toBe("Google Chrome");
  });

  test("'open the X' / 'open the X app' strips the 'the' filler", () => {
    expect(openApp.match(normalize("Open the Linear app"))?.canonical).toBe("Linear");
    expect(openApp.match(normalize("Open the chrome"))?.canonical).toBe("Google Chrome");
  });

  test("'open my X' strips the 'my' filler", () => {
    expect(openApp.match(normalize("Open my chrome"))?.canonical).toBe("Google Chrome");
  });

  test("'fire up X' / 'bring up X' / 'pull up X' all match", () => {
    expect(openApp.match(normalize("Fire up Slack"))?.canonical).toBe("Slack");
    expect(openApp.match(normalize("Bring up Linear"))?.canonical).toBe("Linear");
    expect(openApp.match(normalize("Pull up Spotify"))?.canonical).toBe("Spotify");
  });

  test("politeness tails are stripped before matching", () => {
    expect(openApp.match(normalize("Open Linear please"))?.canonical).toBe("Linear");
    expect(openApp.match(normalize("Open up Linear, thanks."))?.canonical).toBe("Linear");
  });
});
