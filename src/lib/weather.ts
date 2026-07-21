import { Capacitor } from "@capacitor/core";
import { Geolocation } from "@capacitor/geolocation";

/// "Send conditions" (SL-69): friction for climbing is best when it's cool and
/// dry, so we blend temperature + humidity into a 0–100 send score.
export interface SendConditions {
  tempC: number;
  humidity: number; // %
  score: number; // 0–100 absolute
  label: "Prime" | "Good" | "Fair" | "Poor";
  /// Where today's score sits in the last ~30 days of local hourly weather
  /// (SL-91) — 0–100, or null if the history is unavailable/too short. This
  /// is the signal that matters in a hot climate where the absolute score is
  /// always "Poor": "today is better than N% of recent hours here".
  percentile: number | null;
  /// The local 30-day distribution the percentile is measured against
  /// (SL-91b), so the sheet can plot today against it. Null when unavailable.
  hist: ClimateSummary | null;
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

/// Shared colour ramp for an absolute send score (poor → prime). Lifted here
/// (SL-91) so the card and sheet stop duplicating the thresholds.
export function sendScoreColor(score: number): string {
  return score >= 55 ? "var(--success)" : score >= 35 ? "var(--warning)" : "var(--danger)";
}

/// Colour for a local percentile (SL-91): a high percentile is a good day for
/// THIS location regardless of the absolute score.
export function percentileColor(p: number): string {
  return p >= 75 ? "var(--success)" : p >= 40 ? "var(--warning)" : "var(--danger)";
}

/// Where `current` sits within `history` — the fraction of hours scoring
/// strictly lower, as 0–100. Null until there's a meaningful sample (~4 days
/// of hourly data) so a sparse fetch can't produce a misleading percentile.
export function scorePercentile(current: number, history: number[]): number | null {
  if (history.length < 100) return null;
  const below = history.reduce((n, s) => n + (s < current ? 1 : 0), 0);
  return Math.round((below / history.length) * 100);
}

const HIST_KEY = "sendmeter:climate-hist";
/// Weekly cache bucket — the local climate distribution barely moves week to
/// week, so we refetch the (heavier) archive at most once per 7 days.
const weekBucket = (nowMs: number) => Math.floor(nowMs / (7 * 86_400_000));

/// The local 30-day climate the percentile is measured against (SL-91b): the
/// hourly send scores plus the raw temperature/humidity ranges, so the sheet
/// can show today against the whole distribution instead of a bare number.
export interface ClimateSummary {
  scores: number[]; // hourly send scores over the window
  tempMin: number;
  tempMax: number;
  humMin: number;
  humMax: number;
}

interface ClimateHist extends ClimateSummary {
  coordsKey: string;
  week: number;
}

/// Bucket send scores into `bins` equal 0–100 columns — the histogram the
/// sheet draws. Exported for the distribution chart + tests.
export function scoreHistogram(scores: number[], bins = 20): number[] {
  const counts = new Array<number>(bins).fill(0);
  for (const s of scores) {
    const i = Math.min(bins - 1, Math.max(0, Math.floor((s / 100) * bins)));
    counts[i]!++;
  }
  return counts;
}

/// Last ~30 days of hourly local weather, each hour run through the SAME
/// absolute scorer, so the percentile compares like with like. From
/// Open-Meteo's ERA5 archive (which lags ~2 days). Cached per rounded
/// location + week in localStorage. Returns null on any failure — the
/// percentile + distribution just degrade to absent.
async function fetchLocalClimate(
  lat: string,
  lon: string,
): Promise<ClimateSummary | null> {
  const coordsKey = `${lat},${lon}`;
  const week = weekBucket(Date.now());
  try {
    const raw = localStorage.getItem(HIST_KEY);
    if (raw) {
      const c = JSON.parse(raw) as ClimateHist;
      if (c.coordsKey === coordsKey && c.week === week && c.scores?.length) {
        return {
          scores: c.scores,
          tempMin: c.tempMin,
          tempMax: c.tempMax,
          humMin: c.humMin,
          humMax: c.humMax,
        };
      }
    }
  } catch {
    /* ignore malformed cache */
  }
  const iso = (d: Date) => d.toISOString().slice(0, 10);
  const end = new Date(Date.now() - 2 * 86_400_000); // ERA5 lags ~2 days
  const start = new Date(end.getTime() - 30 * 86_400_000);
  try {
    const res = await fetch(
      `https://archive-api.open-meteo.com/v1/era5?latitude=${lat}&longitude=${lon}&start_date=${iso(start)}&end_date=${iso(end)}&hourly=temperature_2m,relative_humidity_2m`,
    );
    if (!res.ok) return null;
    const data = (await res.json()) as {
      hourly?: {
        temperature_2m?: (number | null)[];
        relative_humidity_2m?: (number | null)[];
      };
    };
    const temps = data.hourly?.temperature_2m;
    const hums = data.hourly?.relative_humidity_2m;
    if (!temps || !hums) return null;
    const scores: number[] = [];
    let tempMin = Infinity;
    let tempMax = -Infinity;
    let humMin = Infinity;
    let humMax = -Infinity;
    for (let i = 0; i < temps.length; i++) {
      const t = temps[i];
      const h = hums[i];
      if (t == null || h == null) continue;
      scores.push(computeSendScore(t, h));
      if (t < tempMin) tempMin = t;
      if (t > tempMax) tempMax = t;
      if (h < humMin) humMin = h;
      if (h > humMax) humMax = h;
    }
    if (scores.length === 0) return null;
    const summary: ClimateSummary = { scores, tempMin, tempMax, humMin, humMax };
    try {
      localStorage.setItem(
        HIST_KEY,
        JSON.stringify({ coordsKey, week, ...summary } satisfies ClimateHist),
      );
    } catch {
      /* ignore quota */
    }
    return summary;
  } catch {
    return null;
  }
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
    // Current weather + the local 30-day history in parallel; the archive is
    // best-effort, so the percentile degrades to null without blocking.
    const [data, climate] = await Promise.all([
      fetch(
        `https://api.open-meteo.com/v1/forecast?latitude=${lat}&longitude=${lon}&current=temperature_2m,relative_humidity_2m`,
      )
        .then((res) =>
          res.ok
            ? (res.json() as Promise<{
                current?: {
                  temperature_2m?: number;
                  relative_humidity_2m?: number;
                };
              }>)
            : null,
        )
        .catch(() => null),
      fetchLocalClimate(lat, lon),
    ]);
    const tempC = data?.current?.temperature_2m;
    const humidity = data?.current?.relative_humidity_2m;
    if (tempC == null || humidity == null) return null;
    const score = computeSendScore(tempC, humidity);
    const percentile = climate ? scorePercentile(score, climate.scores) : null;
    return {
      tempC,
      humidity,
      score,
      label: scoreLabel(score),
      percentile,
      hist: climate,
      fetchedAt: Date.now(),
    };
  } catch {
    return null;
  }
}
