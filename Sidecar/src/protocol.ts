import { z } from "zod";

/**
 * The Hark sidecar speaks newline-delimited JSON (NDJSON) over stdio. Each
 * line is one of three discriminated message kinds:
 *
 *   - request   — Swift → sidecar, has an `id` and a `method` name
 *   - response  — sidecar → Swift, mirrors the request id, success or error
 *   - event     — sidecar → Swift, server-pushed (streaming results, logs)
 *
 * Keeping the envelope as a discriminated union lets both sides exhaustively
 * switch on `kind` without conditional fields creeping in.
 */

export const RequestSchema = z.object({
  kind: z.literal("request"),
  id: z.string().min(1),
  method: z.string().min(1),
  params: z.unknown().optional(),
});

export const ResponseSchema = z.discriminatedUnion("ok", [
  z.object({
    kind: z.literal("response"),
    id: z.string().min(1),
    ok: z.literal(true),
    result: z.unknown(),
  }),
  z.object({
    kind: z.literal("response"),
    id: z.string().min(1),
    ok: z.literal(false),
    error: z.string(),
    code: z.string().optional(),
  }),
]);

export const EventSchema = z.object({
  kind: z.literal("event"),
  topic: z.string().min(1),
  payload: z.unknown(),
});

export type Request = z.infer<typeof RequestSchema>;
export type Response = z.infer<typeof ResponseSchema>;
export type Event = z.infer<typeof EventSchema>;

export const ok = (id: string, result: unknown): Response => ({
  kind: "response",
  id,
  ok: true,
  result,
});

export const err = (id: string, message: string, code?: string): Response => {
  const base = { kind: "response" as const, id, ok: false as const, error: message };
  return code === undefined ? base : { ...base, code };
};
