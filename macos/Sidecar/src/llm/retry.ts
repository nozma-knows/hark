/**
 * Exponential-backoff retry wrapper for the Anthropic Messages API.
 * The Anthropic load balancer occasionally returns 5xx/529 ("overloaded")
 * and 429 ("rate limited") under burst; both are transient and clear
 * within seconds. Retrying transparently means a single hiccup doesn't
 * turn into a pill failure that the user sees.
 *
 * Strategy:
 *   - 3 attempts total (initial + 2 retries)
 *   - exponential backoff: 250ms, 750ms (with ±25% jitter)
 *   - retry only on transient HTTP codes; 4xx (except 429) and
 *     malformed-response errors bubble immediately
 */

export interface RetryableError {
  /** HTTP status when known. */
  readonly status?: number;
  /** True for network errors and other non-HTTP transients. */
  readonly transient: boolean;
  readonly message: string;
}

const RETRYABLE_HTTP = new Set([408, 429, 500, 502, 503, 504, 529]);

export function isRetryableHttp(status: number): boolean {
  return RETRYABLE_HTTP.has(status);
}

export interface BackoffOpts {
  maxAttempts?: number;
  /** Base delay in ms — actual delay is `base * 2^attempt` with jitter. */
  baseDelayMs?: number;
  /** Test seam — defaults to setTimeout. */
  sleep?: (ms: number) => Promise<void>;
}

const defaultSleep = (ms: number) =>
  new Promise<void>((resolve) => setTimeout(resolve, ms));

/**
 * Run `fn` with retry on transient errors. `fn` should throw an object
 * that satisfies `RetryableError` so we can distinguish retryable from
 * fatal. Anything else bubbles immediately.
 */
export async function withRetry<T>(
  fn: () => Promise<T>,
  opts: BackoffOpts = {}
): Promise<T> {
  const maxAttempts = opts.maxAttempts ?? 3;
  const baseDelayMs = opts.baseDelayMs ?? 250;
  const sleep = opts.sleep ?? defaultSleep;

  let lastError: unknown;
  for (let attempt = 0; attempt < maxAttempts; attempt++) {
    try {
      return await fn();
    } catch (err) {
      lastError = err;
      const r = err as Partial<RetryableError>;
      const retryable =
        r.transient === true ||
        (typeof r.status === "number" && isRetryableHttp(r.status));
      if (!retryable || attempt === maxAttempts - 1) throw err;
      const jitter = 1 + (Math.random() - 0.5) * 0.5; // ±25%
      const delay = baseDelayMs * 2 ** attempt * jitter;
      await sleep(delay);
    }
  }
  throw lastError;
}
