import { describe, expect, test } from "bun:test";
import { search } from "../search.ts";
import { normalize } from "../normalize.ts";

describe("search.match", () => {
  test("'search Google for X' routes to google", () => {
    const a = search.match(normalize("Search Google for the weather in Tokyo"));
    expect(a?.service).toBe("google");
    expect(a?.query).toBe("the weather in tokyo");
  });

  test("'google X' shortcut routes to google", () => {
    const a = search.match(normalize("Google whisper kit tutorials"));
    expect(a?.service).toBe("google");
    expect(a?.query).toBe("whisper kit tutorials");
  });

  test("'search YouTube for X' routes to youtube", () => {
    const a = search.match(normalize("Search YouTube for whisper kit"));
    expect(a?.service).toBe("youtube");
    expect(a?.query).toBe("whisper kit");
  });

  test("'yt' alias routes to youtube", () => {
    const a = search.match(normalize("Search yt for tutorials"));
    expect(a?.service).toBe("youtube");
  });

  test("'search Gmail for X' routes to gmail", () => {
    const a = search.match(normalize("Search Gmail for emails from xfinity"));
    expect(a?.service).toBe("gmail");
    expect(a?.query).toBe("emails from xfinity");
  });

  test("'search my inbox for X' uses gmail alias", () => {
    const a = search.match(normalize("Search my inbox for receipts"));
    expect(a?.service).toBe("gmail");
    expect(a?.query).toBe("receipts");
  });

  test("'search Linear for X' routes to linear", () => {
    expect(search.match(normalize("Search Linear for billing"))?.service).toBe("linear");
  });

  test("'search GitHub for X' routes to github", () => {
    expect(search.match(normalize("Search GitHub for whisperkit"))?.service).toBe("github");
  });

  test("'find <service> for X' verb variant works", () => {
    const a = search.match(normalize("Find Google for hark voice control"));
    expect(a?.service).toBe("google");
  });

  test("'look up <service> for X' verb variant works", () => {
    const a = search.match(normalize("Look up Google for hark"));
    expect(a?.service).toBe("google");
  });

  test("declines transcripts mentioning 'profile' (chromeProfile owns)", () => {
    expect(search.match(normalize("Search Google for X in my work profile"))).toBeNull();
  });

  test("declines transcripts without a recognized service", () => {
    expect(search.match(normalize("Search Mastodon for X"))).toBeNull();
    expect(search.match(normalize("Find the answer"))).toBeNull();
  });

  test("declines when 'for' separator missing for non-google services", () => {
    expect(search.match(normalize("Search YouTube whisper kit"))).toBeNull();
  });

  test("declines bare 'search'", () => {
    expect(search.match(normalize("Search"))).toBeNull();
    expect(search.match(normalize("Search Google"))).toBeNull();
  });

  test("polite tail stripped via normalize", () => {
    expect(search.match(normalize("Search Google for hark please"))?.query).toBe("hark");
  });
});
