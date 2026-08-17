/// Zod input schemas for the six read-only tools. One source of truth used
/// both for the MCP tool registrations and (via schema.parse in the handler
/// wrapper) for input validation, so an agent gets a clean structured error
/// for bad arguments instead of a thrown stack trace.

import { z } from "zod";

export const dateString = z
  .string()
  .regex(/^\d{4}-\d{2}-\d{2}$/, "expected YYYY-MM-DD")
  .describe("Local calendar date, YYYY-MM-DD");

/// A recording/session id. Real rows use UUIDv4, but legacy and seed rows
/// carry UUID-shaped ids with zero version groups — a strict uuid() check
/// would reject perfectly queryable data. This is an input sanity check;
/// PostgREST does the actual matching.
export const idString = z
  .string()
  .min(1)
  .max(64)
  .regex(/^[A-Za-z0-9-]+$/, "expected an id (UUID or similar)");

export const getHealthMetricsSchema = z.object({
  from: dateString,
  to: dateString,
  metric: z
    .enum(["hrv", "rhr", "sleep", "weight"])
    .optional()
    .describe("Which daily series to return; omitted = all four"),
});

export const getSessionsSchema = z.object({
  from: dateString,
  to: dateString,
  discipline: z
    .string()
    .min(1)
    .max(50)
    .optional()
    .describe("Filter by session type id (e.g. gym, board, fingerboard, outdoor, tindeq, auto)"),
});

export const getReadinessSchema = z.object({
  days: z
    .number()
    .int()
    .min(1)
    .max(365)
    .default(14)
    .describe("How many days of readiness scores, ending today (default 14)"),
});

export const getAcwrSchema = z.object({
  days: z
    .number()
    .int()
    .min(28)
    .max(365)
    .default(90)
    .describe(
      "Display lookback in days (default 90). The ratio itself always uses the full 90-day EWMA window, so this only affects presentation, never the math.",
    ),
});

export const getTindeqSchema = z.object({
  recording_id: idString.optional(),
  session_id: idString.optional(),
  limit: z
    .number()
    .int()
    .min(1)
    .max(50)
    .default(10)
    .describe("Max recordings when neither id is given (most recent first)"),
});

export const analyzeTrainingLoadSchema = z.object({
  weeks: z
    .number()
    .int()
    .min(1)
    .max(16)
    .default(4)
    .describe("How many trailing weeks (ending today) to analyse (default 4)"),
  days: z
    .number()
    .int()
    .min(7)
    .max(365)
    .default(90)
    .describe(
      "Recovery lookback in days for the readiness trend (default 90). The weekly buckets and ACWR always use the full windows they need (weeks*7 and 90 days respectively), so this only affects the recovery summary.",
    ),
});
