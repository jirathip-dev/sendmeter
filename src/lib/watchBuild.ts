import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type { WatchBuildInfo, WatchBuildStatus, WatchSyncStatus } from "sendlog-auth-bridge";

export type { WatchBuildInfo, WatchBuildStatus, WatchSyncStatus };

/// Issue #228: the watch app updates from TestFlight independently of the
/// phone, so the two can sit builds apart — and a pre-#208 watch still rotates
/// the relayed refresh token and revokes the whole session family under a
/// phone that carries the fix. This is the read side: the watch stamps its
/// build onto messages it already sends (see `WatchBuildReport` in
/// SendLogWatchCore), the plugin records it, and the account sheet renders it
/// next to the phone's own build.
///
/// Returns null on web — a browser has no watch, and a row saying "not paired"
/// there would be noise rather than information.
export async function loadWatchBuildInfo(): Promise<WatchBuildInfo | null> {
  if (!Capacitor.isNativePlatform()) return null;
  try {
    const info = await SendLogAuthBridge.getWatchInfo();
    // A native shell whose compiled-in plugin predates this method rejects
    // (caught below) — or, on some Capacitor paths, resolves with nothing.
    return typeof info?.status === "string" ? info : null;
  } catch {
    return null;
  }
}

export type WatchBuildTone = "muted" | "warning";

export interface WatchBuildLine {
  /// The whole line minus the report timestamp, e.g. "Watch 1.3.0 (51) ·
  /// behind this iPhone".
  text: string;
  /// "warning" is the actionable state — the builds differ (#228).
  tone: WatchBuildTone;
  /// Epoch seconds of the last report, only when a build is being shown. A
  /// months-old report describes an install that may have moved on since.
  reportedAt?: number;
}

/// How each status reads. Kept out of the view so the honest-states rule is
/// testable: "not reported" and "not paired" must never render as agreement,
/// and a difference must never render as muted.
const STATUS_DETAIL: Record<WatchBuildStatus, string> = {
  "not-paired": "not paired",
  "app-not-installed": "Sendmeter not installed",
  "not-reported": "build not reported yet",
  match: "same build as this iPhone",
  "watch-behind": "behind this iPhone",
  "watch-ahead": "ahead of this iPhone",
  differs: "differs from this iPhone",
  unknown: "build unknown",
};

const WARNING_STATUSES: ReadonlySet<WatchBuildStatus> = new Set<WatchBuildStatus>([
  "watch-behind",
  "watch-ahead",
  "differs",
]);

export function watchBuildLine(info: WatchBuildInfo | null): WatchBuildLine | null {
  if (!info) return null;
  const detail = STATUS_DETAIL[info.status] ?? STATUS_DETAIL.unknown;
  // The build is only shown when the status says we actually have one to
  // trust: a stale report from a watch that's since been unpaired is history,
  // not the state of the device on the wrist.
  const showsBuild =
    info.watchDisplay !== undefined &&
    info.status !== "not-paired" &&
    info.status !== "app-not-installed" &&
    info.status !== "not-reported";
  const text = showsBuild ? `Watch ${info.watchDisplay} · ${detail}` : `Watch · ${detail}`;
  return {
    text,
    tone: WARNING_STATUSES.has(info.status) ? "warning" : "muted",
    ...(showsBuild && info.reportedAt !== undefined ? { reportedAt: info.reportedAt } : {}),
  };
}

export interface WatchSyncLine {
  /// The whole line minus the report timestamp, e.g. "Watch queue · 3 items
  /// pending sync".
  text: string;
  /// "warning" is the actionable state — items that look stuck (#21).
  tone: WatchBuildTone;
  /// Epoch seconds of the report the count came from, whenever a count is
  /// being shown. A count is only ever as current as its report.
  reportedAt?: number;
}

/// Issue #21: the watch saves workouts and gauge sessions to a persist-first
/// disk queue and drains them on launch/foreground — so a watch that can't
/// reach Supabase (a gym basement, a stale token) holds real training data
/// that never appears on the phone, and nothing on the phone says so. The
/// watch stamps its queue depth onto the messages it already sends, the plugin
/// records it, and this renders the state.
///
/// The honest-states rule matters more here than for the build: an empty queue
/// and a watch that has never reported one look identical if both render as
/// silence, so they say different things. A count also ages — the watch only
/// reports when it talks to the phone, so a three-day-old "4 pending"
/// describes a queue that may since have drained, and says so rather than
/// claiming four items are stuck right now.
///
/// Returns null when there is no queue to describe (web, a paired-watch-less
/// device, a pre-#21 native shell) or when the pairing itself is the story —
/// the build line already says "not paired" / "Sendmeter not installed", and
/// repeating it as a queue state would be noise.
export function watchSyncLine(info: WatchBuildInfo | null): WatchSyncLine | null {
  if (!info) return null;
  const status = info.syncStatus;
  if (status === undefined) return null;
  if (status === "not-paired" || status === "app-not-installed" || status === "unknown") {
    return null;
  }
  if (status === "not-reported") {
    return { text: "Watch queue · sync state not reported yet", tone: "muted" };
  }
  const reported =
    info.pendingSyncReportedAt !== undefined ? { reportedAt: info.pendingSyncReportedAt } : {};
  if (status === "empty") {
    return { text: "Watch queue · empty, everything synced", tone: "muted", ...reported };
  }
  const count = info.pendingSyncCount ?? 0;
  const items = `${count} item${count === 1 ? "" : "s"} pending sync`;
  const stale = info.pendingSyncStale === true;
  return {
    // A stale count must not be read as live: it's what the queue held the
    // last time the watch spoke to this phone, not what it holds now.
    text: `Watch queue · ${items}${stale ? " at last report" : ""}`,
    // Backed up is the "it isn't draining" case; a stale count with items in
    // it is the "and the watch stopped talking" case. Both are actionable.
    tone: status === "backed-up" || stale ? "warning" : "muted",
    ...reported,
  };
}
