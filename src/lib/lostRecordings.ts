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
/// monitoring message. #484 F3 added `"upload-rejected"`: a recording that
/// DID have a durable home, was attempted, and was permanently rejected by
/// the server during a drain — a different cause from the other two (which
/// both mean "no store would take it"), and one the user-facing notice must
/// not phrase as a storage problem.
export type LostRecordingSource =
  | "salvage-on-unmount"
  | "save-failed"
  | "upload-rejected";

export interface LostRecordingNotice {
  /// Recordings lost since the notice was last shown — accumulated, so a
  /// protocol whose every rep failed reports once with the real number.
  count: number;
  /// ISO timestamp of the most recent loss.
  lastAt: string;
  /// Which `LostRecordingSource`s contributed, deduped. Absent on a notice
  /// written before this field existed (or by a legacy caller) — a reader
  /// must treat that as the original, storage-only cause this module used to
  /// report exclusively, never as "unknown".
  reasons?: LostRecordingSource[];
}

function isNotice(v: unknown): v is LostRecordingNotice {
  if (!v || typeof v !== "object") return false;
  const n = v as Record<string, unknown>;
  if (
    typeof n.count !== "number" ||
    !Number.isFinite(n.count) ||
    n.count <= 0 ||
    typeof n.lastAt !== "string"
  ) {
    return false;
  }
  return n.reasons === undefined || Array.isArray(n.reasons);
}

/// Add `count` losses (from `source`) to the pending notice. Returns whether
/// the record actually landed — a store that refuses this too leaves the
/// user with no signal at all, which is exactly what the caller reports to
/// monitoring. Never throws: it runs on paths (an unmount cleanup) that must
/// not fail.
export function noteLostRecordings(
  count: number,
  source: LostRecordingSource,
  storage: NoticeStorage | null = defaultStorage(),
  now: () => string = () => new Date().toISOString(),
): boolean {
  if (!storage || count <= 0) return false;
  try {
    const raw = storage.getItem(STORAGE_KEY);
    const parsed: unknown = raw ? JSON.parse(raw) : null;
    const prevCount = isNotice(parsed) ? parsed.count : 0;
    const prevReasons = isNotice(parsed) && parsed.reasons ? parsed.reasons : [];
    storage.setItem(
      STORAGE_KEY,
      JSON.stringify({
        count: prevCount + count,
        lastAt: now(),
        reasons: [...new Set([...prevReasons, source])],
      }),
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
    detail.noticeStored = noteLostRecordings(1, source, storage, now);
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
