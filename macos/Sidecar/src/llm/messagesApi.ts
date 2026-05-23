import { isRetryableHttp, type RetryableError } from "./retry.ts";

/**
 * Minimal typed wrapper around the Anthropic Messages API. Kept
 * intentionally small — we only model the fields we send and the
 * fields we read; the rest of the API surface (streaming, vision,
 * extended thinking) is irrelevant to a single-tool voice command
 * agent.
 *
 * Exported as a thin function (not a class) so tests can replace it
 * with a fetch-mock by passing a custom `fetchImpl`. The tool loop
 * upstairs is the orchestration layer; this file is just transport.
 */

export interface MessagesRequest {
  model: string;
  max_tokens: number;
  system: SystemBlock[];
  messages: MessageParam[];
  tools: ToolDefinition[];
}

export interface SystemBlock {
  type: "text";
  text: string;
  cache_control?: { type: "ephemeral" };
}

export interface ToolDefinition {
  name: string;
  description: string;
  input_schema: Record<string, unknown>;
}

export interface MessageParam {
  role: "user" | "assistant";
  content: string | ContentBlock[];
}

export type ContentBlock =
  | TextBlock
  | ToolUseBlock
  | ToolResultBlock;

export interface TextBlock {
  type: "text";
  text: string;
}

export interface ToolUseBlock {
  type: "tool_use";
  id: string;
  name: string;
  input: Record<string, unknown>;
}

export interface ToolResultBlock {
  type: "tool_result";
  tool_use_id: string;
  content: string;
  is_error?: boolean;
}

export interface MessagesResponse {
  id: string;
  type: "message";
  role: "assistant";
  content: Array<TextBlock | ToolUseBlock>;
  stop_reason: "end_turn" | "tool_use" | "max_tokens" | "stop_sequence";
  usage: {
    input_tokens: number;
    output_tokens: number;
    cache_read_input_tokens?: number;
    cache_creation_input_tokens?: number;
  };
}

const ENDPOINT = "https://api.anthropic.com/v1/messages";
const ANTHROPIC_VERSION = "2023-06-01";

export interface MessagesApiOpts {
  apiKey: string;
  /** Test seam — defaults to globalThis.fetch. */
  fetchImpl?: typeof fetch;
  /** Per-call HTTP timeout in ms. Defaults to 30s. */
  timeoutMs?: number;
}

/**
 * POST to /v1/messages. Throws a `RetryableError`-shaped object on
 * transient failures so the retry wrapper can replay. 4xx (except 429)
 * are tagged non-transient so callers see them immediately instead of
 * burning retries on a config error.
 */
export async function callMessages(
  request: MessagesRequest,
  opts: MessagesApiOpts
): Promise<MessagesResponse> {
  const fetchImpl = opts.fetchImpl ?? fetch;
  const timeoutMs = opts.timeoutMs ?? 30_000;
  const controller = new AbortController();
  const timer = setTimeout(() => controller.abort(), timeoutMs);

  let response: Response;
  try {
    response = await fetchImpl(ENDPOINT, {
      method: "POST",
      headers: {
        "x-api-key": opts.apiKey,
        "anthropic-version": ANTHROPIC_VERSION,
        "content-type": "application/json",
      },
      body: JSON.stringify(request),
      signal: controller.signal,
    });
  } catch (err) {
    clearTimeout(timer);
    // Network errors, aborts, DNS — all transient from our POV.
    const e: RetryableError = {
      transient: true,
      message: err instanceof Error ? err.message : String(err),
    };
    throw e;
  }
  clearTimeout(timer);

  if (!response.ok) {
    const text = await response.text().catch(() => "");
    const e: RetryableError = {
      status: response.status,
      transient: isRetryableHttp(response.status),
      message: `${response.status} ${response.statusText}: ${text.slice(0, 300)}`,
    };
    throw e;
  }

  const json = (await response.json()) as MessagesResponse;
  return json;
}
