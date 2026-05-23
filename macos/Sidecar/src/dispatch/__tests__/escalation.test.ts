import { describe, expect, test } from "bun:test";
import { isEscalatable, type DispatcherErrorCode } from "../escalation.ts";

/**
 * The escalation contract is the single load-bearing piece of logic
 * that decides whether a dispatcher failure surfaces to the user as a
 * hard error or falls through to the LLM. Exhaustive coverage so a
 * future code added to the union without classification will be caught.
 */
describe("isEscalatable", () => {
  test("app_not_installed → escalatable", () => {
    expect(isEscalatable("app_not_installed")).toBe(true);
  });

  test("profile_not_found → escalatable", () => {
    expect(isEscalatable("profile_not_found")).toBe(true);
  });

  test("bash_failed → non-escalatable (real exit code, LLM can't fix)", () => {
    expect(isEscalatable("bash_failed")).toBe(false);
  });

  test("dispatcher_failed → non-escalatable (catch-all, surface it)", () => {
    expect(isEscalatable("dispatcher_failed")).toBe(false);
  });

  test("undefined → non-escalatable (success path)", () => {
    expect(isEscalatable(undefined)).toBe(false);
  });

  test("type-level exhaustiveness — every member of the union is classified", () => {
    // If a future commit adds a new code to DispatcherErrorCode without
    // classifying it in isEscalatable's switch, TypeScript will flag
    // the switch as non-exhaustive at COMPILE time. This test just
    // pins the runtime behavior on every CURRENT member so we notice
    // if classification flips silently in a refactor.
    const codes: DispatcherErrorCode[] = [
      "app_not_installed",
      "profile_not_found",
      "bash_failed",
      "dispatcher_failed",
    ];
    const escalatable = codes.filter((c) => isEscalatable(c));
    expect(escalatable).toEqual(["app_not_installed", "profile_not_found"]);
  });
});
