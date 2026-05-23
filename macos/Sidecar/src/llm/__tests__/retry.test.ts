import { describe, expect, test } from "bun:test";
import { isRetryableHttp, withRetry } from "../retry.ts";

describe("isRetryableHttp", () => {
  test.each([408, 429, 500, 502, 503, 504, 529])("status %i is retryable", (s) => {
    expect(isRetryableHttp(s)).toBe(true);
  });

  test.each([200, 400, 401, 403, 404, 422])("status %i is NOT retryable", (s) => {
    expect(isRetryableHttp(s)).toBe(false);
  });
});

describe("withRetry", () => {
  const noSleep = async () => {};

  test("succeeds on first try → calls fn exactly once", async () => {
    let calls = 0;
    const result = await withRetry(async () => {
      calls++;
      return "ok";
    });
    expect(result).toBe("ok");
    expect(calls).toBe(1);
  });

  test("retries on retryable HTTP status", async () => {
    let calls = 0;
    const result = await withRetry(
      async () => {
        calls++;
        if (calls < 3) throw { status: 503, transient: true, message: "overloaded" };
        return "ok";
      },
      { sleep: noSleep }
    );
    expect(result).toBe("ok");
    expect(calls).toBe(3);
  });

  test("retries on transient: true (network error)", async () => {
    let calls = 0;
    const result = await withRetry(
      async () => {
        calls++;
        if (calls < 2) throw { transient: true, message: "ECONNRESET" };
        return "ok";
      },
      { sleep: noSleep }
    );
    expect(result).toBe("ok");
    expect(calls).toBe(2);
  });

  test("does NOT retry on non-retryable 4xx", async () => {
    let calls = 0;
    await expect(
      withRetry(
        async () => {
          calls++;
          throw { status: 401, transient: false, message: "unauthorized" };
        },
        { sleep: noSleep }
      )
    ).rejects.toMatchObject({ status: 401 });
    expect(calls).toBe(1);
  });

  test("gives up after maxAttempts", async () => {
    let calls = 0;
    await expect(
      withRetry(
        async () => {
          calls++;
          throw { status: 503, transient: true, message: "overloaded" };
        },
        { sleep: noSleep, maxAttempts: 3 }
      )
    ).rejects.toMatchObject({ status: 503 });
    expect(calls).toBe(3);
  });

  test("respects custom sleep — backoff is invoked between attempts", async () => {
    const delays: number[] = [];
    await expect(
      withRetry(
        async () => {
          throw { status: 503, transient: true, message: "overloaded" };
        },
        {
          sleep: async (ms) => {
            delays.push(ms);
          },
          baseDelayMs: 100,
          maxAttempts: 3,
        }
      )
    ).rejects.toBeDefined();
    // Two sleeps between three attempts; each within ±25% of base * 2^attempt.
    expect(delays).toHaveLength(2);
    expect(delays[0]).toBeGreaterThanOrEqual(75);
    expect(delays[0]).toBeLessThanOrEqual(125);
    expect(delays[1]).toBeGreaterThanOrEqual(150);
    expect(delays[1]).toBeLessThanOrEqual(250);
  });
});
