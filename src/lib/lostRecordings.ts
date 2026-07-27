import { captureDataLoss } from "./monitoring";
import type { PersistResult } from "./recordingQueue";

// #264: the reporting half of recordingQueue's persist policy (the block above
// `persistRecording` is where the DECISION is written down; this is what
// carries it out). Two channels, because neither alone is enough:
//
//   * Sentry — durable, reaches us, and is the only channel that works for the
//     salvage-on-unmount path in a build we don't hold. It is also inert
//     without a build-time DSN, so it is never the user's only signal.
//   * A one-shot notice in storage — the user pulled a rep and deserves to
//     know it did not survive, but the path that loses it (useTindeq's unmount
//     cleanup) has no UI it can reach. So the fact is parked and App.tsx
//     surfaces it on the next mount/foreground, then clears it.
//
// The notice is stored in `localStorage`, the same store that just refused a
// write. That is not an oversight: the refused write is a recording (hundreds
// of KB), this record is ~60 bytes, and a quota-exhausted store will usually
// still take the small one. When it doesn't, `noticeStored=false` rides along
// in the Sentry event so we can tell "user was told" from "user never knew".

const STORAGE_KEY = "sendmeter:lost-recordings";

export interface NoticeStorage {
  getItem(key: string): string | null;
  setItem(key: string, value: string): void;
  removeItem(key: string): void;
}

function defaultStorage(): NoticeStorage | null {
  try {
    return typeof localStorage === "undefined" ? null : localStorage;
  } catch {
    return null; // storage disabled (private mode, native shell quirks, …)
  }
}

/// Which code path lost the recording. A closed set, because it lands in a
/// monitoring message.
export type LostRecordingSource = "salvage-on-unmount" | "save-failed";

export interface LostRecordingNotice {
  /// Recordings lost since the notice was last shown — accumulated, so a
  /// protocol whose every rep failed reports once with the real number.
  count: number;
  /// ISO timestamp of the most recent loss.
  lastAt: string;
}

function isNotice(v: unknown): v is LostRecordingNotice {
  if (!v || typeof v !== "object") return false;
  const n = v as Record<string, unknown>;
  return (
    typeof n.count === "number" &&
    Number.isFinite(n.count) &&
    n.count > 0 &&
    typeof n.lastAt === "string"
  );
}

/// Add `count` losses to the pending notice. Returns whether the record
/// actually landed — a store that refuses this too leaves the user with no
/// signal at all, which is exactly what the caller reports to monitoring.
/// Never throws: it runs on paths (an unmount cleanup) that must not fail.
export function noteLostRecordings(
  count: number,
  storage: NoticeStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): boolean {
  if (!storage || count <= 0) return false;
  try {
    const raw = storage.getItem(STORAGE_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    const prev = isNotice(parsed) ? parsed.count : 0;
    storage.setItem(
      STORAGE_KEY,
      JSON.stringify({ count: prev + count, lastAt: now() }),
    );
    return true;
  } catch {
    return false;
  }
}

/// Read the pending notice AND clear it, so it is shown exactly once. A
/// corrupt/absent record reads as "nothing to say".
export function takeLostRecordingsNotice(
  storage: NoticeStorage | null = defaultStorage(),
): LostRecordingNotice | null {
  if (!storage) return null;
  try {
    const raw = storage.getItem(STORAGE_KEY);
    if (!raw) return null;
    storage.removeItem(STORAGE_KEY);
    const parsed: unknown = JSON.parse(raw);
    return isNotice(parsed) ? parsed : null;
  } catch {
    return null;
  }
}

/// The single place both persist call sites report from, so the salvage path
/// and the ForceView path can never drift on what a lost rep means.
///
/// Evictions are reported to MONITORING ONLY: dropping the oldest queued entry
/// is the queue's designed degradation (see MAX_QUEUE_BYTES), and a rep that
/// has already failed to sync repeatedly is not what the user is standing at
/// the board waiting on. The user-facing notice is reserved for the recording
/// that has no durable home at all.
export function reportPersistFailure(
  source: LostRecordingSource,
  result: PersistResult,
  sampleCount: number,
  storage: NoticeStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): void {
  if (result.persisted && result.evicted === 0) return;
  const detail: Record<string, number | boolean> = {
    evicted: result.evicted,
    samples: sampleCount,
  };
  if (!result.persisted) {
    detail.lost = 1;
    // Kept even when it is `true`: "the user was told" is half the finding.
    detail.noticeStored = noteLostRecordings(1, storage, now);
  }
  // Still worth having in a dev console, where Sentry is deliberately inert.
  console.warn(
    `[tindeq] ${source}: ${
      result.persisted
        ? "recording queued"
        : "recording could not be queued — no durable copy exists"
    }`,
    detail,
  );
  captureDataLoss(`tindeq-recording:${source}`, detail);
}
