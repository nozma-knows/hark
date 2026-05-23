import { describe, expect, test } from "bun:test";
import { normalize } from "../normalize.ts";

describe("normalize", () => {
  test("lowercases", () => {
    expect(normalize("Open Linear")).toBe("open linear");
  });

  test("strips trailing punctuation (Whisper artifact)", () => {
    expect(normalize("Open Linear.")).toBe("open linear");
    expect(normalize("take a screenshot!")).toBe("take a screenshot");
    expect(normalize("what is this?")).toBe("what is this");
  });

  test("collapses interior whitespace", () => {
    expect(normalize("open    linear")).toBe("open linear");
    expect(normalize("open\tlinear")).toBe("open linear");
  });

  test("trims surrounding whitespace", () => {
    expect(normalize("  open linear  ")).toBe("open linear");
  });

  test("preserves interior punctuation that's part of intent", () => {
    expect(normalize("open github.com")).toBe("open github.com");
  });

  test("handles empty string", () => {
    expect(normalize("")).toBe("");
    expect(normalize("   ")).toBe("");
  });
});
