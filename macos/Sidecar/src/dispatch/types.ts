/**
 * Shared contracts for the tool layer. Each tool lives in its own file
 * under `dispatch/` and is collected into the runtime registry by
 * `registry.ts`. The LLM is the router: it reads the user's transcript,
 * picks a tool by name, fills the JSON-schema-validated `input`, and
 * the registry runs the matching `execute` to do the work.
 *
 * This replaces the older "dispatcher" pattern (regex match() → execute())
 * which routed before the LLM ever saw the transcript. The regex layer
 * was brittle — phrases starting with "open" were eaten by the open-app
 * matcher even when the user meant something more specific ("open a
 * Juggle task to fix the pill bug"). Now the LLM sees the whole sentence
 * and picks the right tool.
 *
 * Splitting input schema (declarative, JSON) from execution (imperative,
 * side-effecting) keeps the LLM-facing surface and the macOS-facing
 * surface independently testable.
 */

import type { ZodRawShape } from "zod";

export interface Tool<TInput> {
  /** Stable machine-name. Used as the tool's name on the Anthropic
   *  Messages API and as the MCP tool suffix on the Agent SDK path. */
  readonly name: string;

  /** One-paragraph description used by the LLM to choose this tool.
   *  Should describe WHEN to pick it (in plain English) and any
   *  non-obvious behaviour the model needs to know. */
  readonly description: string;

  /** Anthropic Messages API input schema. JSON Schema, draft 7-ish —
   *  Anthropic accepts `{ type: "object", properties: { … }, required: [...] }`. */
  readonly inputSchema: Record<string, unknown>;

  /** Same shape, expressed as a Zod raw shape — used by the Agent SDK
   *  `tool()` helper which accepts `Record<string, ZodType>`. Defined
   *  once per tool (the inputSchema is the JSON-rendered form of it). */
  readonly zodShape: ZodRawShape;

  /** Runtime validator. Receives the raw `input` JSON from the model
   *  and either returns a typed action or throws a descriptive Error.
   *  Throwing maps to an `is_error: true` tool_result; the LLM gets
   *  another turn to retry with corrected arguments. */
  parseInput(raw: unknown): TInput;

  /** Side-effecting execution. MUST NOT throw — every failure path
   *  maps to `{ succeeded: false, error }` so the caller can render
   *  a pill without a try/catch. */
  execute(input: TInput): Promise<ExecutionResult>;
}

export interface ExecutionResult {
  /** Human-readable summary shown in the pill. */
  summary: string;
  succeeded: boolean;
  /** Set when `succeeded` is false; surfaced in logs, not the pill. */
  error?: string | undefined;
  /** Every bash command we actually ran on the user's machine. */
  bashCommands: string[];
}

/**
 * Type-erased view of a tool. The registry uses this so the LLM clients
 * can iterate tools without thinking about each tool's input shape.
 */
export interface ToolEntry {
  readonly name: string;
  readonly description: string;
  readonly inputSchema: Record<string, unknown>;
  readonly zodShape: ZodRawShape;
  /** Pre-bound: parses + executes, returning a uniform result. */
  invoke(raw: unknown): Promise<ExecutionResult>;
}

/**
 * Erase a typed tool into a uniform `ToolEntry`. Captures parsing +
 * execution into a single `invoke()` so registry consumers don't
 * have to know about each tool's input type.
 */
export function asEntry<T>(tool: Tool<T>): ToolEntry {
  return {
    name: tool.name,
    description: tool.description,
    inputSchema: tool.inputSchema,
    zodShape: tool.zodShape,
    async invoke(raw) {
      let parsed: T;
      try {
        parsed = tool.parseInput(raw);
      } catch (err) {
        const message =
          err instanceof Error ? err.message : String(err);
        return {
          summary: `Invalid arguments for ${tool.name}: ${message}`,
          succeeded: false,
          error: `bad_arguments: ${message}`,
          bashCommands: [],
        };
      }
      return tool.execute(parsed);
    },
  };
}
