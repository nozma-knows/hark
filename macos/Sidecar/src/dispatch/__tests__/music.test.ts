import { describe, expect, test } from "bun:test";
import { music } from "../music.ts";
import { normalize } from "../normalize.ts";

// Narrow expected-command type so `expect(...).toBe(expected)` typechecks
// against the dispatcher's command union without needing per-row casts.
type Cmd = NonNullable<ReturnType<typeof music.match>>["command"];
type Row = [string, Cmd];

describe("music.match", () => {
  test.each<Row>([
    ["play music", "play"],
    ["Play music", "play"],
    ["resume music", "play"],
    ["start music", "play"],
    ["play", "play"],
  ])("plays — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test.each<Row>([
    ["pause", "pause"],
    ["pause music", "pause"],
    ["pause the music", "pause"],
  ])("pauses — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test.each<Row>([
    ["next song", "next"],
    ["next track", "next"],
    ["next", "next"],
    ["skip song", "next"],
    ["skip", "next"],
  ])("skips forward — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test.each<Row>([
    ["previous song", "previous"],
    ["previous track", "previous"],
    ["back", "previous"],
    ["prev", "previous"],
  ])("skips back — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test.each<Row>([
    ["stop music", "stop"],
    ["stop", "stop"],
  ])("stops — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test.each<Row>([
    ["play pause", "toggle"],
    ["playpause", "toggle"],
    ["toggle play/pause", "toggle"],
  ])("toggles — %p", (transcript, expected) => {
    expect(music.match(normalize(transcript))?.command).toBe(expected);
  });

  test("strips trailing politeness via normalize", () => {
    expect(music.match(normalize("Play music please"))?.command).toBe("play");
    expect(music.match(normalize("Skip track, thanks."))?.command).toBe("next");
  });

  test("declines transcripts that aren't music control", () => {
    expect(music.match(normalize("open Music"))).toBeNull();
    expect(music.match(normalize("what's playing"))).toBeNull();
    expect(music.match(normalize("play youtube"))).toBeNull();
  });
});
