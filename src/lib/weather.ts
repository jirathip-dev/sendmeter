import { Capacitor } from "@capacitor/core";
import { Geolocation } from "@capacitor/geolocation";

/// "Send conditions" (SL-69): friction for climbing is best when it's cool and
/// dry, so we blend temperature + humidity into a 0–100 send score.
export interface SendConditions {
  tempC: number;
  humidity: number; // %
  score: number; // 0–100 absolute
  label: "Prime" | "Good" | "Fair" | "Poor";
  /// Where right now ranks against the SAME local hour of day on the last
  /// ~30 days (issue #99) — 0–100, or null if there are fewer than 20 such
  /// days. This is the signal that matters in a hot climate where the
  /// absolute score is always "Poor": "3pm today is better than N of the
  /// last M 3pm's here", comparing like with like instead of pooling every
  /// hour (night vs. midday) into one distribution.
  percentile: number | null;
  /// Raw counts behind `percentile` — the countable claim the banner makes.
  /// Null exactly when `percentile` is null.
  daysBelow: number | null;
  daysTotal: number | null;
  /// Local hour (0–23) the reading was taken, used to pull the matching
  /// same-hour series out of `hist` at render time. Computed once here (not
  /// in render — react-compiler forbids impure `Date.now()`/`getHours()` in
  /// render bodies).
  hourOfDay: number;
  /// The local 30-day climate history `percentile` is measured against
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

export function scoreLabel(score: number): SendConditions["label"] {
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

/// Every day's send score at a given local hour-of-day, chronological, nulls
/// dropped — `hist.scores` is aligned so index `i` is day `floor(i/24)`, hour
/// `i%24` (see `fetchLocalClimate`'s `&timezone=auto`). This is the series
/// `dayRank` compares `current` against: same time of day, different days.
export function sameHourScores(scores: (number | null)[], hourOfDay: number): number[] {
  const out: number[] = [];
  for (let i = hourOfDay; i < scores.length; i += 24) {
    const s = scores[i];
    if (s != null) out.push(s);
  }
  return out;
}

/// Where `current` ranks among `dayScores` (typically `sameHourScores`'
/// output) — the count scoring strictly lower, the total, and the resulting
/// percentile. Null when there are fewer than 20 days: too sparse to claim a
/// rank at a single hour of day.
export function dayRank(
  current: number,
  dayScores: number[],
): { below: number; total: number; percentile: number } | null {
  const total = dayScores.length;
  if (total < 20) return null;
  const below = dayScores.reduce((n, s) => n + (s < current ? 1 : 0), 0);
  return { below, total, percentile: Math.round((below / total) * 100) };
}

/// Label for a same-hour-of-day percentile (issue #99) — aligned with
/// `percentileColor`'s thresholds so Prime and Good both read as the same
/// green: ≥90 is the top decile ("Prime"), ≥75 "Good", ≥40 "Fair", else
/// "Poor".
export function percentileLabel(p: number): SendConditions["label"] {
  if (p >= 90) return "Prime";
  if (p >= 75) return "Good";
  if (p >= 40) return "Fair";
  return "Poor";
}

const HIST_KEY = "sendmeter:climate-hist-v2";
/// Weekly cache bucket — the local climate distribution barely moves week to
/// week, so we refetch the (heavier) archive at most once per 7 days.
const weekBucket = (nowMs: number) => Math.floor(nowMs / (7 * 86_400_000));

/// The local 30-day climate the percentile is measured against (issue #99):
/// hourly send scores aligned to LOCAL time (index `i` = day `floor(i/24)`,
/// hour `i%24` — see `fetchLocalClimate`'s `&timezone=auto`) plus the raw
/// temperature/humidity ranges, so the sheet can show today against the
/// same-hour history instead of a bare number. `scores[i]` is null for an
/// hour the archive didn't return — kept as a placeholder (not skipped) so
/// the day/hour index arithmetic stays valid.
export interface ClimateSummary {
  scores: (number | null)[]; // hourly send scores over the window, local-time aligned
  tempMin: number;
  tempMax: number;
  humMin: number;
  humMax: number;
}

interface ClimateHist extends ClimateSummary {
  coordsKey: string;
  week: number;
}

/// Last ~30 days of hourly local weather, each hour run through the SAME
/// absolute scorer, so the day comparison compares like with like. From
/// Open-Meteo's ERA5 archive (which lags ~2 days), requested with
/// `&timezone=auto` so the hourly arrays align to LOCAL time rather than UTC.
/// Cached per rounded location + week in localStorage. Returns null on any
/// failure — the percentile just degrades to absent.
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
    // Two accepted limitations, not engineered around:
    // (a) `timezone=auto` returns ONE fixed UTC offset for the whole range —
    //     days on the far side of a DST transition inside the 30-day window
    //     are off by 1 hour against `sameHourScores`' hour-of-day index. Fine
    //     for a weather hint, not for anything that needs to be exact.
    // (b) `hourOfDay` (below, in `fetchSendConditions`) comes from the
    //     device's clock, which matches the weather location except while
    //     travelling across timezones before this cache (bucketed weekly)
    //     expires — the same-hour comparison would then be comparing the
    //     wrong local hour at the new location.
    const res = await fetch(
      `https://archive-api.open-meteo.com/v1/era5?latitude=${lat}&longitude=${lon}&start_date=${iso(start)}&end_date=${iso(end)}&hourly=temperature_2m,relative_humidity_2m&timezone=auto`,
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
    // Push null (not skip) for a missing hour — skipping would shift every
    // later index off its day/hour-of-day slot and break `sameHourScores`.
    const scores: (number | null)[] = [];
    let tempMin = Infinity;
    let tempMax = -Infinity;
    let humMin = Infinity;
    let humMax = -Infinity;
    for (let i = 0; i < temps.length; i++) {
      const t = temps[i];
      const h = hums[i];
      if (t == null || h == null) {
        scores.push(null);
        continue;
      }
      scores.push(computeSendScore(t, h));
      if (t < tempMin) tempMin = t;
      if (t > tempMax) tempMax = t;
      if (h < humMin) humMin = h;
      if (h > humMax) humMax = h;
    }
    if (tempMin === Infinity) return null; // every hour was null
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

// ---- Fake-mode fixtures (browser-testable, no geolocation/network) --------
// `?fake-weather` (default scenario "hot") or `?fake-weather=<scenario>` short-
// circuits `fetchSendConditions` into returning a synthesized, deterministic
// `SendConditions` — mirrors `?fake-tindeq` (see useTindeq.ts) so Send
// Conditions can be exercised in `npm run dev:local` without a device's
// location or live Open-Meteo calls. Scenarios:
//   hot     (default) — issue #99: current 35°C/45% is absolute Poor but ranks
//           in the top decile against the SAME hour of day on the other ~30
//           days (percentile ≥90 at every hour — verified by a script, see
//           `fakeHotHistory`).
//   prime   — current 5°C/30% against a mild-climate history → absolute
//           Prime, and ≥90th same-hour percentile at every hour (verified —
//           see `fakePrimeHistory`).
//   bad     — the SAME hot-climate history as `hot`, but a worse current
//           reading (36°C/95%) → a low same-hour percentile ("below par for
//           here").
//   no-hist — current reading with no local history at all (hist/percentile
//           both null) — exercises the degraded UI (no banner, no chart).
const weatherParams =
  typeof window !== "undefined" ? new URLSearchParams(window.location.search) : null;
export const WEATHER_FAKE_MODE = weatherParams?.has("fake-weather") ?? false;
const WEATHER_FAKE_SCENARIO = weatherParams?.get("fake-weather") || "hot";

/// Deterministic (no `Math.random`) hourly diurnal pattern for a fake ~30-day
/// climate history — 30 days × 24h = 720 samples, the same shape a real ERA5
/// pull returns (no nulls). Temp/humidity each swing over the day between
/// `mid ± amp` following a shaped cosine peaking at 15:00 (mid-afternoon
/// heat); `p` > 1 narrows the extremes (e.g. a brief afternoon dry snap
/// rather than half the day), and a `phaseOffsetHours` lag on humidity lets a
/// few hours land near the day's optimum instead of humidity being a pure
/// mirror image of temperature. A small day-to-day drift (`sin` over the
/// ~30-day window) adds gentle variation on top. `dryWetAmp` (default 0)
/// layers in a SEPARATE, rare brief-dry-spell event across days — near 0 most
/// days (wetter, `+dryWetAmp`) but collapsing to the plain diurnal value for
/// the ~1 day nearest `dryPhaseDay`, `dryQ` controlling how narrow that dip
/// is — so a day-to-day comparison at a fixed hour has real spread instead of
/// the diurnal cycle repeating near-identically every day (which is what
/// `sameHourScores` would otherwise compare against). Every hour is run
/// through the same `computeSendScore` the real path uses, tracking min/max
/// exactly like `fetchLocalClimate` does.
function fakeHistory(opts: {
  tempMid: number;
  tempAmp: number;
  humMid: number;
  humAmp: number;
  p?: number;
  phaseOffsetHours?: number;
  dryWetAmp?: number;
  dryPhaseDay?: number;
  dryQ?: number;
}): ClimateSummary {
  const {
    tempMid,
    tempAmp,
    humMid,
    humAmp,
    p = 1,
    phaseOffsetHours = 0,
    dryWetAmp = 0,
    dryPhaseDay = 15,
    dryQ = 40,
  } = opts;
  const shaped = (theta: number) => Math.sign(Math.cos(theta)) * Math.abs(Math.cos(theta)) ** p;
  const scores: (number | null)[] = [];
  let tempMin = Infinity;
  let tempMax = -Infinity;
  let humMin = Infinity;
  let humMax = -Infinity;
  for (let i = 0; i < 720; i++) {
    const hourOfDay = i % 24;
    const day = Math.floor(i / 24);
    const thetaT = (2 * Math.PI * (hourOfDay - 15)) / 24;
    const thetaH = (2 * Math.PI * (hourOfDay - 15 + phaseOffsetHours)) / 24;
    const dayTheta = (2 * Math.PI * day) / 30;
    const dryPulseTheta = (2 * Math.PI * (day - dryPhaseDay)) / 30;
    const dryPulse = Math.abs(Math.cos(dryPulseTheta / 2)) ** dryQ;
    const t = tempMid + tempAmp * shaped(thetaT) + 0.5 * Math.sin(dayTheta);
    const h = humMid - humAmp * shaped(thetaH) + 2 * Math.sin(dayTheta + 1) + dryWetAmp * (1 - dryPulse);
    scores.push(computeSendScore(t, h));
    if (t < tempMin) tempMin = t;
    if (t > tempMax) tempMax = t;
    if (h < humMin) humMin = h;
    if (h > humMax) humMax = h;
  }
  return { scores, tempMin, tempMax, humMin, humMax };
}

// Same hot-climate shape backs both `hot` and `bad` (bad just reads a worse
// current value against it): history temps ~25–36°C, humidity ~40–76%, with
// one brief dry-spell day (`dryWetAmp`/`dryQ`, dipping near 40%) so the
// same-hour-of-day comparison has real day-to-day spread rather than the
// diurnal cycle alone (which repeats almost identically every day and would
// make `hot`'s current reading tie the trough instead of beating it).
// Verified (see the PR description's percentile check) that `hot`'s current
// (35°C/45%) ranks ≥90th percentile against every one of the 24 hours-of-day.
function fakeHotHistory(): ClimateSummary {
  return fakeHistory({
    tempMid: 30.5,
    tempAmp: 5,
    humMid: 54,
    humAmp: 12,
    p: 4,
    dryWetAmp: 8,
    dryQ: 150,
  });
}

// Current 5°C/30% (score 83) against a mild, wide-swinging climate — tuned so
// the current reading is at least tied by every historical hour rather than
// beaten by some (a `tempMid` off-optimum, e.g. the previous 7.5°C, lets the
// diurnal cycle pass exactly through the 6°C peak at some hour every day,
// which then beats a merely-good current reading at that hour on every one
// of the 30 days — percentile 0, not a fluke). `tempMid` at the scorer's own
// optimum (6°C, current is 5°C) plus a humidity floor (18%) still drier than
// current's 30% keeps `prime` ≥90th percentile at all 24 hours-of-day
// (verified — see the PR description's percentile table).
function fakePrimeHistory(): ClimateSummary {
  return fakeHistory({ tempMid: 5, tempAmp: 8, humMid: 50, humAmp: 30 });
}

/// Pure fixture builder for `?fake-weather=<scenario>`, decoupled from the
/// wall clock so it's testable for every hour-of-day (unlike `fakeSendConditions`,
/// which supplies the real current hour). Exported for tests only.
export function fakeSendConditionsForHour(scenario: string, hourOfDay: number): SendConditions {
  const fetchedAt = Date.now();
  const build = (tempC: number, humidity: number, hist: ClimateSummary | null): SendConditions => {
    const score = computeSendScore(tempC, humidity);
    const rank = hist ? dayRank(score, sameHourScores(hist.scores, hourOfDay)) : null;
    return {
      tempC,
      humidity,
      score,
      label: scoreLabel(score),
      percentile: rank?.percentile ?? null,
      daysBelow: rank?.below ?? null,
      daysTotal: rank?.total ?? null,
      hourOfDay,
      hist,
      fetchedAt,
    };
  };
  if (scenario === "prime") {
    return build(5, 30, fakePrimeHistory());
  }
  if (scenario === "bad") {
    return build(36, 95, fakeHotHistory());
  }
  if (scenario === "no-hist") {
    return build(35, 45, null);
  }
  // "hot" (default) — issue #99.
  return build(35, 45, fakeHotHistory());
}

function fakeSendConditions(scenario: string): SendConditions {
  return fakeSendConditionsForHour(scenario, new Date().getHours());
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
  if (WEATHER_FAKE_MODE) return fakeSendConditions(WEATHER_FAKE_SCENARIO);
  const coords = await getCoords();
  if (!coords) return null;
  const lat = coords.lat.toFixed(2);
  const lon = coords.lon.toFixed(2);
  const hourOfDay = new Date().getHours();
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
    const rank = climate ? dayRank(score, sameHourScores(climate.scores, hourOfDay)) : null;
    return {
      tempC,
      humidity,
      score,
      label: scoreLabel(score),
      percentile: rank?.percentile ?? null,
      daysBelow: rank?.below ?? null,
      daysTotal: rank?.total ?? null,
      hourOfDay,
      hist: climate,
      fetchedAt: Date.now(),
    };
  } catch {
    return null;
  }
}
