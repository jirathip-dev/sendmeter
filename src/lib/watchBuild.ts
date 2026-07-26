import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type { WatchBuildInfo, WatchBuildStatus } from "sendlog-auth-bridge";

export type { WatchBuildInfo, WatchBuildStatus };

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
