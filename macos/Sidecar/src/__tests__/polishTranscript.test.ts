import { describe, expect, test } from "bun:test";
import { POLISH_PROFILES, PROFILE_PROMPTS, resolveProfile } from "../polishTranscript.ts";

describe("polishTranscript profile resolution", () => {
  test.each([...POLISH_PROFILES])("accepts canonical name %p", (name) => {
    expect(resolveProfile(name)).toBe(name);
  });

  test("falls back to standard for unknown names", () => {
    expect(resolveProfile("super-formal")).toBe("standard");
    expect(resolveProfile("CASUAL")).toBe("standard");
    expect(resolveProfile("")).toBe("standard");
  });

  test("falls back to standard for non-strings", () => {
    expect(resolveProfile(undefined)).toBe("standard");
  });
});

describe("PROFILE_PROMPTS", () => {
  test("every profile has a non-empty prompt", () => {
    for (const profile of POLISH_PROFILES) {
      const prompt = PROFILE_PROMPTS[profile];
      expect(typeof prompt).toBe("string");
      expect(prompt.length).toBeGreaterThan(50);
    }
  });

  test("every prompt has the shared output-only rule", () => {
    for (const profile of POLISH_PROFILES) {
      expect(PROFILE_PROMPTS[profile]).toContain("Output ONLY the cleaned transcript text");
    }
  });

  test("casual prompt explicitly keeps contractions", () => {
    expect(PROFILE_PROMPTS.casual).toContain("Keep contractions");
  });

  test("formal prompt expands contractions", () => {
    expect(PROFILE_PROMPTS.formal).toContain("Expand contractions");
  });

  test("code prompt protects technical identifiers", () => {
    expect(PROFILE_PROMPTS.code).toContain("VERBATIM");
  });
});
