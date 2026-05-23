import { describe, expect, test } from "bun:test";
import { openUrl } from "../openUrl.ts";
import { normalize } from "../normalize.ts";

describe("openUrl.match", () => {
  test("matches 'open <domain.tld>'", () => {
    expect(openUrl.match(normalize("Open github.com"))?.url).toBe("https://github.com");
    expect(openUrl.match(normalize("Open youtube.com"))?.url).toBe("https://youtube.com");
  });

  test("matches 'go to <site>'", () => {
    expect(openUrl.match(normalize("Go to twitter.com"))?.url).toBe("https://twitter.com");
  });

  test("matches 'navigate to <site>' / 'visit <site>'", () => {
    expect(openUrl.match(normalize("Navigate to news.ycombinator.com"))?.url).toBe(
      "https://news.ycombinator.com"
    );
    expect(openUrl.match(normalize("Visit example.org"))?.url).toBe("https://example.org");
  });

  test("preserves explicit https://", () => {
    expect(openUrl.match(normalize("Open https://github.com"))?.url).toBe("https://github.com");
  });

  test("converts 'X dot Y' to 'X.Y'", () => {
    expect(openUrl.match(normalize("Open youtube dot com"))?.url).toBe("https://youtube.com");
    expect(openUrl.match(normalize("Open news dot ycombinator dot com"))?.url).toBe(
      "https://news.ycombinator.com"
    );
  });

  test("matches paths after the host", () => {
    expect(openUrl.match(normalize("Open github.com/anthropics"))?.url).toBe(
      "https://github.com/anthropics"
    );
  });

  test("does NOT claim plain app names", () => {
    expect(openUrl.match(normalize("Open Linear"))).toBeNull();
    expect(openUrl.match(normalize("Open Chrome"))).toBeNull();
  });

  test("does NOT claim 'open X in Y profile'", () => {
    expect(openUrl.match(normalize("Open youtube.com in my work profile"))).toBeNull();
  });

  test("declines non-open verbs", () => {
    expect(openUrl.match(normalize("delete github.com"))).toBeNull();
  });
});
