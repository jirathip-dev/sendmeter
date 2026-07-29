/// Selected-preset persistence (SL-76): ForceView unmounts on tab switch and
/// its preset state dies with it, so PresetManager remembers the armed id
/// here and re-arms it on mount. Owned by this module (not PresetManager.tsx)
/// so ForceView can clear it too (#296 — a zone taking over must not leave a
/// stale id that re-arms the preset past the zone on the next mount).
export const FORCE_PRESET_SELECTED_KEY = "sendmeter:force-preset";

export function clearPersistedPreset() {
  localStorage.removeItem(FORCE_PRESET_SELECTED_KEY);
}
