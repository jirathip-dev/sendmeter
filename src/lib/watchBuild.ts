import { Capacitor } from "@capacitor/core";
import { SendLogAuthBridge } from "sendlog-auth-bridge";
import type {
  WatchBuildInfo,
  WatchBuildStatus,
  WatchQuarantineStatus,
  WatchSyncStatus,
} from "sendlog-auth-bridge";
import type { PluginListenerHandle } from "@capacitor/core";

export type { WatchBuildInfo, WatchBuildStatus, WatchQuarantineStatus, WatchSyncStatus };

export type WatchStatusTone = "positive" | "muted" | "warning";

export interface WatchStatusPresentation {
  title: string;
  detail: string;
  tone: WatchStatusTone;
  /// Build identities are secondary detail, never the status sentence.
  watchDisplay?: string;
  phoneDisplay?: string;
  /// Epoch seconds. Only present when the displayed watch build is trusted.
  reportedAt?: number;
}

export interface UploadWarningItem {
  /// "watch-quarantined" is distinct from "watch" (#475 F1): a quarantined
  /// item is not "waiting to upload" — and "watch-quarantined-retrying"
  /// (#475 F13) is distinct again from "watch-quarantined": the two
  /// `QuarantineReason` cases need different, non-interchangeable copy (one
  /// truly never syncs on its own, the other gets one more automatic
  /// attempt), so telling the user the wrong one would be actively
  /// misleading about their own data. All three sources can be present at
  /// once, so they need separate keys, not a shared row.
  
  /// #484: `"phone-stuck"` is a recording the server has rejected across an
  /// app-version change (see the policy block above `drainQueue` in
  /// recordingQueue.ts) — retained on device, no longer auto-retried. Kept
  /// as its own source rather than folded into `"phone"`: different cause,
  /// different (and the only) recovery — `retryStuckRecordings`, which the
  /// view wires to an actual button for this source.
  
  source:
    | "watch"
    | "watch-quarantined"
    | "watch-quarantined-retrying"
    | "phone"
    | "phone-stuck";
  text: string;
  detail: string;
  /// Epoch seconds of the watch queue report. A historical count is only as
  /// useful as its age, so the view renders this beside stale wording.
  reportedAt?: number;
}

export interface UploadWarningPresentation {
  title: string;
  items: UploadWarningItem[];
}

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

export function onWatchInfoChanged(
  handler: () => void,
): Promise<PluginListenerHandle | null> {
  if (!Capacitor.isNativePlatform()) return Promise.resolve(null);
  return SendLogAuthBridge.addListener("watchInfoChanged", handler);
}

const CONNECTED_TITLE = "Connected & installed";

/// Issue #369: user-facing pairing/install/build presentation for Account.
/// This deliberately selects a small allow-list from the native response;
/// no auth state or watch payload can accidentally become display content.
export function watchStatusPresentation(
  info: WatchBuildInfo | null,
): WatchStatusPresentation | null {
  if (!info) return null;

  switch (info.status) {
    case "not-paired":
      return {
        title: "No watch paired",
        detail: "Pair an Apple Watch with this iPhone to use Sendmeter on your wrist.",
        tone: "muted",
      };
    case "app-not-installed":
      return {
        title: "App not installed",
        detail: "Install Sendmeter on the paired watch from the Watch app on this iPhone.",
        tone: "warning",
      };
    case "not-reported":
      return {
        title: CONNECTED_TITLE,
        detail: "The watch app has not reported its build yet.",
        tone: "muted",
      };
    case "match":
      return connectedWatchStatus(info, "Build matches this iPhone.", "positive");
    case "watch-behind":
      return connectedWatchStatus(
        info,
        "The watch build is behind this iPhone. Update it from the Watch app.",
        "warning",
      );
    case "watch-ahead":
      return connectedWatchStatus(
        info,
        "The watch build is ahead of this iPhone.",
        "warning",
      );
    case "differs":
      return connectedWatchStatus(
        info,
        "The watch build differs from this iPhone.",
        "warning",
      );
    case "unknown":
    default:
      return {
        title: "Checking watch status",
        detail: "Pairing and installation status are not available yet.",
        tone: "muted",
      };
  }
}

function connectedWatchStatus(
  info: WatchBuildInfo,
  detail: string,
  tone: WatchStatusTone,
): WatchStatusPresentation {
  return {
    title: CONNECTED_TITLE,
    detail,
    tone,
    ...(info.watchDisplay ? { watchDisplay: info.watchDisplay } : {}),
    ...(info.phoneDisplay ? { phoneDisplay: info.phoneDisplay } : {}),
    ...(info.reportedAt !== undefined ? { reportedAt: info.reportedAt } : {}),
  };
}

/// Issue #369: the History tab is quiet when uploads are healthy or unknown,
/// and visible only when the user can act on a pending or stale queue.
///
/// #484: `phoneUploads` is the `{pending, stuck}` split
/// (`pendingRecordingsBreakdown`) rather than one number — a stuck recording
/// gets its OWN item (`"phone-stuck"`), not folded into the pending count or
/// dropped, because there is nothing "waiting to upload" about it any more
/// and the count with zero readers is exactly the #475 F1 mistake this repo
/// already paid for once, on the watch.
export function uploadWarningPresentation(
  watchInfo: WatchBuildInfo | null,
  phoneUploads: { pending: number | null; stuck: number | null },
): UploadWarningPresentation | null {
  const items: UploadWarningItem[] = [];
  const syncStatus = watchInfo?.syncStatus;
  const watchCanReport =
    syncStatus === "empty" || syncStatus === "pending" || syncStatus === "backed-up";

  if (watchInfo && watchCanReport && watchInfo.pendingSyncStale === true) {
    const count = watchInfo.pendingSyncCount;
    items.push({
      source: "watch",
      text:
        count !== undefined && count > 0
          ? `Apple Watch last reported ${count} item${count === 1 ? "" : "s"} waiting to upload.`
          : "Apple Watch has not reported upload status recently.",
      detail:
        count !== undefined && count > 0
          ? "Open Sendmeter on the watch to refresh this report and retry."
          : "Its last report showed no items waiting. Open Sendmeter on the watch to refresh it.",
      ...(watchInfo.pendingSyncReportedAt !== undefined
        ? { reportedAt: watchInfo.pendingSyncReportedAt }
        : {}),
    });
  } else if (watchInfo && (syncStatus === "pending" || syncStatus === "backed-up")) {
    const count = watchInfo.pendingSyncCount;
    items.push({
      source: "watch",
      text:
        count !== undefined
          ? `Apple Watch · ${count} item${count === 1 ? "" : "s"} waiting to upload.`
          : "Apple Watch has items waiting to upload.",
      detail: "Open Sendmeter on the watch to retry.",
      ...(watchInfo.pendingSyncReportedAt !== undefined
        ? { reportedAt: watchInfo.pendingSyncReportedAt }
        : {}),
    });
  }

  // #475 F1/F13: a quarantined item is NEVER phrased as "waiting to
  // upload" — but the two `QuarantineReason` cases also need DIFFERENT
  // copy from each other: `.schemaRejection` truly never syncs on its own,
  // `.stuckRetrying` gets one more automatic attempt after a backoff.
  // Telling the user the wrong one is worse than not splitting them.
  // Independent of the pending block above: a watch can have pending items
  // AND both kinds of quarantined ones at once.
  if (watchInfo?.quarantineStatus === "stuck") {
    const total = watchInfo.quarantinedSyncCount;
    const stuckRetrying = watchInfo.quarantinedStuckSyncCount;
    // An older watch build (or plugin) reports only the combined total —
    // that's "breakdown unknown", not "zero stuck-retrying". Defaulting the
    // unknown remainder to the cautious "permanent" framing matches this
    // app's honest-states rule: never silently understate a problem.
    const permanent = total !== undefined ? Math.max(0, total - (stuckRetrying ?? 0)) : undefined;

    if (permanent === undefined || permanent > 0) {
      items.push({
        source: "watch-quarantined",
        text:
          permanent !== undefined
            ? `Apple Watch · ${permanent} workout${permanent === 1 ? "" : "s"} could not be uploaded and will not retry.`
            : "Apple Watch has workouts that could not be uploaded and will not retry.",
        detail: "This data is stuck on the watch. Contact support if this keeps happening.",
        ...(watchInfo.quarantinedSyncReportedAt !== undefined
          ? { reportedAt: watchInfo.quarantinedSyncReportedAt }
          : {}),
      });
    }

    if (stuckRetrying !== undefined && stuckRetrying > 0) {
      items.push({
        source: "watch-quarantined-retrying",
        text: `Apple Watch · ${stuckRetrying} workout${stuckRetrying === 1 ? "" : "s"} having trouble uploading — retrying automatically.`,
        detail: "No action needed. This can take a few days to resolve on its own.",
        ...(watchInfo.quarantinedStuckSyncReportedAt !== undefined
          ? { reportedAt: watchInfo.quarantinedStuckSyncReportedAt }
          : {}),
      });
    }
  }

  if (phoneUploads.stuck !== null && phoneUploads.stuck > 0) {
    const n = phoneUploads.stuck;
    items.push({
      source: "phone-stuck",
      text: `This iPhone · ${n} Force recording${n === 1 ? "" : "s"} stuck — the server keeps rejecting ${n === 1 ? "it" : "them"} and ${n === 1 ? "it" : "they"} won't retry automatically.`,
      detail: "Retry now, or wait for the next app update.",
    });
  }

  if (phoneUploads.pending !== null && phoneUploads.pending > 0) {
    const n = phoneUploads.pending;
    items.push({
      source: "phone",
      text: `This iPhone · ${n} Force recording${n === 1 ? "" : "s"} waiting to upload.`,
      detail: "Keep Sendmeter open with an internet connection to retry.",
    });
  }

  if (items.length === 0) return null;
  return {
    // Not a regex sniff of text THIS function just generated — "waiting to
    // upload" is only ever a watch item's own wording; the phone sources are
    // judged directly by their kind. A stuck-only phone still reads as
    // "Uploads waiting" (it's true, it's just not automatic).
    title: items.some(
      (item) =>
        item.source === "phone" ||
        item.source === "phone-stuck" ||
        (item.source === "watch" && /waiting to upload/.test(item.text)),
    )
      ? "Uploads waiting"
      : "Check Apple Watch uploads",
    items,
  };
}
