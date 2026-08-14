/// #612 F1/F2: the bounded, time-based dedupe for the foreground auth
/// re-relay — a pure policy so the interleavings the in-flight guard got
/// wrong are testable without a React renderer or fake timers.
///
/// A single foreground can arrive as TWO signals — WebKit's
/// `visibilitychange` and the Capacitor native→JS bridge's `appStateChange` —
/// delivered on separate run-loop turns. The two-pass dedupe problem is:
///
/// - An **in-flight-only** guard (the first attempt, removed by #612 review
///   F1) merges only signals that arrive while the read is still pending.
///   When the stored access token is valid — the common foreground — the
///   read resolves in a few microtasks, before the second signal lands, so
///   the second pass runs anyway: doubled `getSession`, doubled relay,
///   doubled `syncHealthNow` (which has no in-flight guard of its own).
/// - A guard with no bound lets a never-settling read (auth-js issues its
///   refresh fetch with no abort signal; a captive portal / dead TCP neither
///   resolves nor rejects) suppress the relay for the rest of the launch
///   (F2).
/// - A wall-clock (`Date.now()`) guard goes false for any `now` before
///   `lastStartedAt`: a system clock corrected backwards suppresses every
///   relay for the size of the jump — the same silent self-disable class,
///   through a different door (review N1).
///
/// The window is measured from when a pass STARTS, not when it settles:
/// a fast resolve doesn't reopen the window, and a hung read can't latch it.
/// A pass is suppressed only when another pass started less than `windowMs`
/// ago; anything else — including a signal long after a read that is still
/// pending — starts a new pass.
///
/// The clock is MONOTONIC (`performance.now()`): it never runs backwards
/// across wall-clock correction, so N1's failure mode cannot occur. The
/// first-pass state is `null` rather than `0` because `performance.now()` is
/// small (a few hundred ms) right after page load — a `0` sentinel would
/// wrongly suppress the first pass until the window elapsed.

export const FOREGROUND_RELAY_DEDUPE_MS = 1000;

/// The monotonic foreground clock, shared with the health-sync flight bound
/// (`healthSync.ts`). `performance.now()` is available in every environment
/// the app runs in (WKWebView, browser, tests).
let clock: () => number = () => performance.now();

/// Test seam — replace the monotonic clock.
export function setForegroundRelayClockForTest(fn: () => number): void {
  clock = fn;
}

/// The current monotonic foreground time, in ms.
export function foregroundRelayNow(): number {
  return clock();
}

/// Whether a new relay pass may start at `now`, given the last one started
/// at `lastStartedAt`. `null` means no pass has started this launch yet —
/// the first pass always starts, even when the caller's clock origin is
/// recent.
export function shouldStartForegroundRelay(
  now: number,
  lastStartedAt: number | null,
  windowMs: number = FOREGROUND_RELAY_DEDUPE_MS,
): boolean {
  if (lastStartedAt === null) return true;
  return now - lastStartedAt >= windowMs;
}
