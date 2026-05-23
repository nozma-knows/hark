import { describe, expect, test } from "bun:test";
import { clipboard } from "../clipboard.ts";
import { normalize } from "../normalize.ts";

describe("clipboard.match", () => {
  test("matches 'copy X to my clipboard'", () => {
    expect(clipboard.match(normalize("Copy github.com to my clipboard"))?.text).toBe(
      "github.com"
    );
  });

  test("matches 'copy X to clipboard' (no possessive)", () => {
    expect(clipboard.match(normalize("Copy hello world to clipboard"))?.text).toBe(
      "hello world"
    );
  });

  test("matches 'copy X to the clipboard'", () => {
    expect(clipboard.match(normalize("Copy foo to the clipboard"))?.text).toBe("foo");
  });

  test("matches 'put X on (the/my) clipboard'", () => {
    expect(clipboard.match(normalize("Put hello on my clipboard"))?.text).toBe("hello");
    expect(clipboard.match(normalize("Put bar in the clipboard"))?.text).toBe("bar");
  });

  test("declines plain 'copy X' without clipboard target", () => {
    expect(clipboard.match(normalize("Copy file"))).toBeNull();
  });

  test("declines unrelated transcripts", () => {
    expect(clipboard.match(normalize("Open Linear"))).toBeNull();
  });
});
