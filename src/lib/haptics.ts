import { Capacitor } from "@capacitor/core";
import { Haptics, ImpactStyle } from "@capacitor/haptics";

/// A light haptic tick for chart scrubbing / point selection (SL-68). Native
/// only (no-op on web), fire-and-forget, never throws.
export function selectionHaptic(): void {
  if (!Capacitor.isNativePlatform()) return;
  void Haptics.impact({ style: ImpactStyle.Light }).catch(() => {});
}
