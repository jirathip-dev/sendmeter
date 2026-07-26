import { Capacitor } from "@capacitor/core";
import { Haptics, ImpactStyle, NotificationType } from "@capacitor/haptics";
import {
  candidateFor,
  createGestureTracker,
  GESTURE_FRESH_MS,
  hapticForCandidate,
  type HapticKind,
  type TapElementLike,
} from "./tapHaptics";

/// The single native call. Fire-and-forget, native-only (no-op on web), and
/// wrapped so a haptic failure can never throw into — or reject inside — the
/// action it accompanies.
function fire(kind: HapticKind): void {
  if (!Capacitor.isNativePlatform()) return;
  try {
    const p =
      kind === "blocked"
        ? Haptics.notification({ type: NotificationType.Warning })
        : Haptics.impact({
            style: kind === "medium" ? ImpactStyle.Medium : ImpactStyle.Light,
          });
    void p.catch(() => {});
  } catch {
    /* plugin missing or throwing synchronously — feedback is never critical */
  }
}

/// A light haptic tick for chart scrubbing / point selection (SL-68) and for
/// the intensity slider (#172). UNGUARDED on purpose: both fire once per
/// *value change* within a single drag, which is exactly the repeat the tap
/// guard below is built to swallow. Callers own their own equal-value guard.
export function selectionHaptic(): void {
  fire("light");
}

const tracker = createGestureTracker();

/// A light tick for an interactive action, at most once per pointer gesture.
/// Nearly every tap is already covered by the delegated listener below — call
/// this only where there is no element to tap (a sheet's backdrop dismiss or
/// drag-to-close release).
export function tapHaptic(): void {
  if (tracker.claim(Date.now())) fire("light");
}

/// A medium tick for a confirm/destructive action. Prefer `data-haptic="medium"`
/// on the button itself (ConfirmDialog does), which routes through the same
/// guard; this is the escape hatch for a confirm with no button behind it.
export function confirmHaptic(): void {
  if (tracker.claim(Date.now())) fire("medium");
}

/// The tick a sheet fires as it mounts. Two guards, both load-bearing: the
/// gesture guard means the tap that OPENED the sheet already spent this
/// gesture's tick (so opening never double-buzzes), and the freshness window
/// means a sheet that appears without a tap behind it — an auto-prompt, a
/// restored session — stays silent rather than buzzing out of nowhere.
export function sheetHaptic(): void {
  if (tracker.claim(Date.now(), { requireGestureWithinMs: GESTURE_FRESH_MS }))
    fire("light");
}

let uninstall: (() => void) | null = null;

/// Duck-typed rather than `instanceof Element`: the event target may be a text
/// node (no `closest`), and the check has to hold outside a browser too — the
/// suite runs in node, where there is no `Element` global to compare against.
function elementFor(target: EventTarget | null): TapElementLike | null {
  const el = target as Partial<TapElementLike> | null;
  return el && typeof el.closest === "function" ? (el as TapElementLike) : null;
}

/// App-wide tap feedback: one delegated listener set instead of ~140 edited
/// call sites. Resolution happens on `pointerup`, not `pointerdown` — a
/// scroll or drag that begins on a button must not buzz, and only the lift
/// tells the two apart (see `TAP_SLOP_PX`). Idempotent; returns an uninstall.
export function installTapHaptics(target: Document = document): () => void {
  if (uninstall) return uninstall;

  const onDown = (e: PointerEvent) => {
    const kind = hapticForCandidate(candidateFor(elementFor(e.target)));
    tracker.down(
      { pointerId: e.pointerId, x: e.clientX, y: e.clientY },
      kind,
      Date.now(),
    );
  };
  const onMove = (e: PointerEvent) => {
    tracker.move({ pointerId: e.pointerId, x: e.clientX, y: e.clientY });
  };
  const onUp = (e: PointerEvent) => {
    const kind = tracker.up(e.pointerId);
    if (kind) fire(kind);
  };
  const onCancel = (e: PointerEvent) => tracker.cancel(e.pointerId);

  // Capture phase so a component's `stopPropagation` (InfoDot's, the session
  // rows') can't silence feedback; passive because this never calls
  // preventDefault and must not cost the scroll a frame.
  const opts = { capture: true, passive: true } as const;
  target.addEventListener("pointerdown", onDown, opts);
  target.addEventListener("pointermove", onMove, opts);
  target.addEventListener("pointerup", onUp, opts);
  target.addEventListener("pointercancel", onCancel, opts);

  uninstall = () => {
    target.removeEventListener("pointerdown", onDown, opts);
    target.removeEventListener("pointermove", onMove, opts);
    target.removeEventListener("pointerup", onUp, opts);
    target.removeEventListener("pointercancel", onCancel, opts);
    uninstall = null;
  };
  return uninstall;
}
