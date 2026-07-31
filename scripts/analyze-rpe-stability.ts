#!/usr/bin/env node
/* global process */

import { existsSync, readFileSync } from "node:fs";
import { homedir } from "node:os";
import { join } from "node:path";
import {
  analyzeRpeStability,
  type DriftStats,
  type RpeStabilityRecording,
  type RpeStabilitySession,
} from "../src/lib/rpeStability";
import type { RecordedZone } from "../src/lib/force-curve";
import type { TindeqSide } from "../src/types";

const PROJECTS = {
  dev: "mjkndfhjnipomjjhgsxv",
  prod: "zznsqmcewtzlnfoiefkk",
} as const;

type Target = keyof typeof PROJECTS;

interface RecordingRow {
  id: string;
  user_id: string;
  recorded_at: string;
  duration_ms: number;
  peak_kg: number;
  avg_kg: number;
  tag: string;
  side: string;
  group_id: string | null;
  zone: string | null;
  samples: [number, number][];
}

interface SessionRow {
  id: string;
  user_id: string;
  group_id: string;
  type: string;
  rpe: number;
  rpe_confirmed: boolean;
}

function usage(): never {
  console.error(
    "Usage: npm run analyze:rpe-stability -- --target dev|prod [--json]\n" +
      "Read-only: queries active Tindeq rows via the Supabase Management API and prints aggregates only.",
  );
  process.exit(2);
}

function targetFromArgs(): Target {
  const index = process.argv.indexOf("--target");
  const value = index === -1 ? null : process.argv[index + 1];
  if (value !== "dev" && value !== "prod") return usage();
  return value;
}

function accessToken(): string {
  const fromEnv = process.env.SUPABASE_ACCESS_TOKEN?.trim();
  if (fromEnv) return fromEnv;
  const path = join(homedir(), ".supabase", "access-token");
  if (existsSync(path)) return readFileSync(path, "utf8").trim();
  console.error("No Supabase Management API token found. Set SUPABASE_ACCESS_TOKEN.");
  process.exit(2);
}

async function query<T>(token: string, ref: string, sql: string): Promise<T[]> {
  const response = await fetch(
    `https://api.supabase.com/v1/projects/${ref}/database/query`,
    {
      method: "POST",
      headers: {
        Authorization: `Bearer ${token}`,
        "Content-Type": "application/json",
      },
      body: JSON.stringify({ query: sql }),
    },
  );
  if (!response.ok) {
    throw new Error(`Management API query failed: HTTP ${response.status} ${await response.text()}`);
  }
  const body: unknown = await response.json();
  if (Array.isArray(body)) return body as T[];
  if (body && typeof body === "object") {
    const shaped = body as { result?: T[]; rows?: T[] };
    return shaped.result ?? shaped.rows ?? [];
  }
  return [];
}

function normalizeRecording(row: RecordingRow): RpeStabilityRecording {
  return {
    id: row.id,
    userId: row.user_id,
    recordedAt: row.recorded_at,
    durationMs: Number(row.duration_ms),
    peakKg: Number(row.peak_kg),
    avgKg: Number(row.avg_kg),
    tag: row.tag,
    side: row.side as TindeqSide,
    groupId: row.group_id,
    zone: row.zone as RecordedZone | null,
    samples: (row.samples ?? []).map(([t, kg]) => ({ t: Number(t), kg: Number(kg) })),
  };
}

function normalizeSession(row: SessionRow): RpeStabilitySession {
  return {
    id: row.id,
    userId: row.user_id,
    groupId: row.group_id,
    type: row.type,
    rpe: Number(row.rpe),
    rpeConfirmed: row.rpe_confirmed,
  };
}

function statLine(label: string, stats: DriftStats): string {
  const value = (n: number | null) => (n === null ? "—" : n.toFixed(2));
  return (
    `${label.padEnd(18)} n=${String(stats.count).padEnd(4)} ` +
    `median=${value(stats.median).padEnd(5)} p90=${value(stats.p90).padEnd(5)} ` +
    `>0.5=${stats.overHalfPoint.pct.toFixed(1)}% ` +
    `>1.0=${stats.overOnePoint.pct.toFixed(1)}%`
  );
}

const target = targetFromArgs();
const ref = PROJECTS[target];
const token = accessToken();
const [recordingRows, sessionRows] = await Promise.all([
  query<RecordingRow>(
    token,
    ref,
    `select id, user_id, recorded_at, duration_ms, peak_kg, avg_kg, tag, side,
            group_id, zone, samples
       from public.tindeq_recordings
      where deleted_at is null
      order by user_id, recorded_at`,
  ),
  query<SessionRow>(
    token,
    ref,
    `select id, user_id, group_id, type, rpe, rpe_confirmed
       from public.sessions
      where deleted_at is null
        and type = 'tindeq'
        and group_id is not null`,
  ),
]);

const report = analyzeRpeStability({
  recordings: recordingRows.map(normalizeRecording),
  sessions: sessionRows.map(normalizeSession),
});

if (process.argv.includes("--json")) {
  console.log(
    JSON.stringify(
      {
        target,
        totalMatchedSessions: report.totalMatchedSessions,
        sessionsWithEffort: report.sessionsWithEffort,
        fullyMeasuredAtBaseline: report.fullyMeasuredAtBaseline,
        notFullyMeasuredAtBaseline: report.notFullyMeasuredAtBaseline,
        sessionsWithRelevantRefit: report.sessionsWithRelevantRefit,
        maximumDrift: report.maximumDrift,
        latestDrift: report.latestDrift,
        maximumWPrimeOnlyDrift: report.maximumWPrimeOnlyDrift,
        maximumCfOnlyDrift: report.maximumCfOnlyDrift,
        byLongestEffort: report.byLongestEffort,
        byDistinctLongWindows: report.byDistinctLongWindows,
        byReviewStatus: report.byReviewStatus,
      },
      null,
      2,
    ),
  );
} else {
  console.log(`RPE stability backtest — ${target}`);
  console.log(`Matched Tindeq sessions:       ${report.totalMatchedSessions}`);
  console.log(`Sessions with effort:          ${report.sessionsWithEffort}`);
  console.log(`Fully measured at baseline:    ${report.fullyMeasuredAtBaseline}`);
  console.log(`Not fully measured at baseline:${String(report.notFullyMeasuredAtBaseline).padStart(5)}`);
  console.log(`Sessions with a later refit:   ${report.sessionsWithRelevantRefit}`);
  console.log("");
  console.log(statLine("Maximum drift", report.maximumDrift));
  console.log(statLine("Latest drift", report.latestDrift));
  console.log(statLine("W′-only maximum", report.maximumWPrimeOnlyDrift));
  console.log(statLine("CF-only maximum", report.maximumCfOnlyDrift));
  console.log("\nMaximum drift by longest fitted effort:");
  for (const row of report.byLongestEffort) {
    console.log(statLine(`  ${row.label}`, row.maximumDrift));
  }
  console.log("\nMaximum drift by distinct long windows:");
  for (const row of report.byDistinctLongWindows) {
    console.log(statLine(`  ${row.label}`, row.maximumDrift));
  }
  console.log("\nMaximum drift by RPE review status:");
  for (const row of report.byReviewStatus) {
    console.log(statLine(`  ${row.label}`, row.maximumDrift));
  }
  console.log("\nNo user IDs, tags, session IDs, or raw samples are printed.");
}
