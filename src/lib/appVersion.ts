import { App } from "@capacitor/app";
import { Capacitor } from "@capacitor/core";

/// Issue #202: a recorded auth event is only attributable if it names the
/// build that produced it. TestFlight builds land days apart, `fastlane beta`
/// injects the build number at archive time (so it isn't in the repo), and the
/// account sheet showed neither — meaning "did the build with the fix still do
/// this?" was unanswerable from the device.
///
/// Cached synchronously after one async read so the record path (which must
/// not await) can stamp events with it.
let cachedTag: string | null = null;

/// `"1.4.0 (57)"` on native once loaded, else null (web, or before the first
/// `loadBuildTag()`). Never throws.
export function buildTag(): string | null {
  return cachedTag;
}

export async function loadBuildTag(): Promise<string | null> {
  if (cachedTag) return cachedTag;
  if (!Capacitor.isNativePlatform()) return null;
  try {
    const info = await App.getInfo();
    cachedTag = `${info.version} (${info.build})`;
  } catch {
    // A shell without the App plugin is not worth failing a launch over.
    cachedTag = null;
  }
  return cachedTag;
}

/// Test seam — the module-level cache would otherwise leak between cases.
export function setBuildTagForTest(tag: string | null): void {
  cachedTag = tag;
}
