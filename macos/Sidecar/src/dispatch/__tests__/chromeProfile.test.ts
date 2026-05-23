import { describe, expect, test } from "bun:test";
import { chromeProfile } from "../chromeProfile.ts";
import { normalize } from "../normalize.ts";

describe("chromeProfile.match", () => {
  test("matches 'open <url> in my <name> profile'", () => {
    const a = chromeProfile.match(normalize("Open youtube.com in my work profile"));
    expect(a?.url).toBe("https://youtube.com");
    expect(a?.profile.name).toBe("work");
  });

  test("matches without 'my'", () => {
    const a = chromeProfile.match(normalize("Open github.com in personal profile"));
    expect(a?.url).toBe("https://github.com");
    expect(a?.profile.name).toBe("personal");
  });

  test("handles 'dot' phrasing in the URL", () => {
    const a = chromeProfile.match(normalize("Open github dot com in my work profile"));
    expect(a?.url).toBe("https://github.com");
  });

  test("handles app names (not URLs) — passes the target through unchanged", () => {
    // "open Linear in my work profile" is a weird command but should still
    // be claimed by chromeProfile to suppress openApp matching it.
    const a = chromeProfile.match(normalize("Open Linear in my work profile"));
    expect(a).not.toBeNull();
    expect(a?.profile.name).toBe("work");
  });

  test("multi-word profile names", () => {
    const a = chromeProfile.match(normalize("Open github.com in my side projects profile"));
    expect(a?.profile.name).toBe("side projects");
  });

  test("declines transcripts without 'profile'", () => {
    expect(chromeProfile.match(normalize("Open youtube.com"))).toBeNull();
    expect(chromeProfile.match(normalize("Open github.com in work mode"))).toBeNull();
  });

  test("declines non-open verbs", () => {
    expect(chromeProfile.match(normalize("close github.com in work profile"))).toBeNull();
  });

  // MARK: - Filler word + compound verb variations

  test("'open up X in Y profile' strips the 'up' filler", () => {
    const a = chromeProfile.match(normalize("Open up github.com in my work profile"));
    expect(a?.url).toBe("https://github.com");
    expect(a?.profile.name).toBe("work");
  });

  test("'pull up X in Y profile' matches", () => {
    const a = chromeProfile.match(normalize("Pull up github.com in personal profile"));
    expect(a?.url).toBe("https://github.com");
    expect(a?.profile.name).toBe("personal");
  });
});
