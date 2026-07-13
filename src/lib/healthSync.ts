import { Capacitor, registerPlugin } from "@capacitor/core";

const IS_NATIVE = Capacitor.isNativePlatform();

// Late-bound handle to the native SendLogHealth plugin (Part 3 / Feature 1).
// registerPlugin gives a proxy without a hard dependency on the plugin
// package, so this file builds and no-ops today; once the native plugin
// ships and `cap sync` wires it in, these calls start doing real work with
// no changes here.
interface SendLogHealthPlugin {
  syncNow(): Promise<void>;
}

const SendLogHealth = registerPlugin<SendLogHealthPlugin>("SendLogHealth");

/// Ask the iPhone to re-read HealthKit and re-upsert today's metrics right
/// now (e.g. immediately after a clear). No-op on web or if the native
/// plugin isn't present yet — the device otherwise picks data back up on its
/// next background delivery, so a failure here is not fatal to the clear.
export async function syncHealthNow(): Promise<void> {
  if (!IS_NATIVE) return;
  try {
    await SendLogHealth.syncNow();
  } catch {
    // plugin not installed yet / method unavailable — safe to ignore
  }
}
