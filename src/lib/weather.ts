import { Capacitor } from "@capacitor/core";
import { Geolocation } from "@capacitor/geolocation";

/// "Send conditions" (SL-69): friction for climbing is best when it's cool and
/// dry, so we blend temperature + humidity into a 0–100 send score.
export interface SendConditions {
  tempC: number;
  humidity: number; // %
  score: number; // 0–100
  label: "Prime" | "Good" | "Fair" | "Poor";
  fetchedAt: number; // epoch ms
}

const clamp = (v: number, lo: number, hi: number) => Math.min(hi, Math.max(lo, v));

/// Temperature sub-score: peak friction ≈ 6°C, falling off ~6 pts per °C away.
export function tempFrictionScore(tempC: number): number {
  return clamp(100 - Math.abs(tempC - 6) * 6, 0, 100);
}

/// Humidity sub-score: drier = better (0% → 100, ~90% → 0).
export function humidityFrictionScore(humidity: number): number {
  return clamp(100 - humidity * 1.1, 0, 100);
}

/// Overall send score: 60% temperature, 40% humidity.
export function computeSendScore(tempC: number, humidity: number): number {
  return Math.round(
    0.6 * tempFrictionScore(tempC) + 0.4 * humidityFrictionScore(humidity),
  );
}

function scoreLabel(score: number): SendConditions["label"] {
  if (score >= 75) return "Prime";
  if (score >= 55) return "Good";
  if (score >= 35) return "Fair";
  return "Poor";
}

async function getCoords(): Promise<{ lat: number; lon: number } | null> {
  try {
    if (Capacitor.isNativePlatform()) {
      let perm = await Geolocation.checkPermissions();
      if (perm.location !== "granted") perm = await Geolocation.requestPermissions();
      if (perm.location !== "granted") return null;
      const pos = await Geolocation.getCurrentPosition({ timeout: 10000 });
      return { lat: pos.coords.latitude, lon: pos.coords.longitude };
    }
    if (!navigator.geolocation) return null;
    return await new Promise((resolve) => {
      navigator.geolocation.getCurrentPosition(
        (p) => resolve({ lat: p.coords.latitude, lon: p.coords.longitude }),
        () => resolve(null),
        { timeout: 10000 },
      );
    });
  } catch {
    return null;
  }
}

/// Fetch current temp + humidity for the device's location and derive the send
/// score. Returns null if location is unavailable/denied. Coordinates are
/// rounded to ~1 km before hitting the (keyless, public) Open-Meteo API so we
/// don't ship a precise location off-device.
export async function fetchSendConditions(): Promise<SendConditions | null> {
  const coords = await getCoords();
  if (!coords) return null;
  const lat = coords.lat.toFixed(2);
  const lon = coords.lon.toFixed(2);
  try {
    const res = await fetch(
      `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,relative_humidity_2m`,
    );
    if (!res.ok) return null;
    const data = (await res.json()) as {
      current?: { temperature_2m?: number; relative_humidity_2m?: number };
    };
    const tempC = data.current?.temperature_2m;
    const humidity = data.current?.relative_humidity_2m;
    if (tempC == null || humidity == null) return null;
    const score = computeSendScore(tempC, humidity);
    return { tempC, humidity, score, label: scoreLabel(score), fetchedAt: Date.now() };
  } catch {
    return null;
  }
}
