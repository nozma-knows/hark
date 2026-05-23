import { describe, expect, test } from "bun:test";
import { screencapture } from "../screencapture.ts";
import { normalize } from "../normalize.ts";

describe("screencapture.match", () => {
  test.each([
    "Take a screenshot",
    "Screenshot",
    "Capture the screen",
    "Capture screen",
    "Grab a screenshot",
    "Take screenshot",
    "Grab screenshot",
  ])("matches '%s'", (phrase) => {
    expect(screencapture.match(normalize(phrase))).not.toBeNull();
  });

  test("strips Whisper-added trailing punctuation", () => {
    expect(screencapture.match(normalize("Take a screenshot."))).not.toBeNull();
  });

  test("declines unrelated transcripts", () => {
    expect(screencapture.match(normalize("Open Linear"))).toBeNull();
    expect(screencapture.match(normalize("take a screenshot of github"))).toBeNull();
  });
});
