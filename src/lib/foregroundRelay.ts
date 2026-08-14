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
///
/// The window is measured from when a pass STARTS, not when it settles:
/// a fast resolve doesn't reopen the window, and a hung read can't latch it.
/// A pass is suppressed only when another pass started less than `windowMs`
/// ago; anything else — including a signal long after a read that is still
/// pending — starts a new pass.

export const FOREGROUND_RELAY_DEDUPE_MS = 1000;

/// Whether a new relay pass may start at `now`, given the last one started
/// at `lastStartedAt`. `lastStartedAt` is `0` before any pass this launch —
/// real epoch times are ≫ window, so the first pass always starts.
export function shouldStartForegroundRelay(
  now: number,
  lastStartedAt: number,
  windowMs: number = FOREGROUND_RELAY_DEDUPE_MS,
): boolean {
  return now - lastStartedAt >= windowMs;
}
