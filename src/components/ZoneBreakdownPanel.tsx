import { useState } from "react";
import {
  QUALITIES,
  ZONE_PROTOCOLS,
  type TrainingQuality,
} from "../lib/force-curve";
import {
  holdOrigin,
  ZONE_BAND_CAVEAT,
  ZONE_BANDS,
  zoneBreakdown,
  type ZoneHold,
} from "../lib/zoneBreakdown";
import { QUALITY_COLORS } from "../lib/zoneSelection";
import type { TindeqRecordingMeta } from "../types";

interface Props {
  /// The holds in scope — already filtered by the caller (one exercise over a
  /// window on the Force tab; one session's recordings in History).
  recs: TindeqRecordingMeta[];
  /// Show each hold's exercise tag. A session can mix exercises; the
  /// training-balance page is already scoped to one, so it doesn't.
  showTag?: boolean;
}

const fmt1 = (n: number) => (Math.round(n * 10) / 10).toFixed(1);

function sideLabel(side: TindeqRecordingMeta["side"]): string | null {
  if (!side) return null;
  return side === "both" ? "L+R" : side === "left" ? "L" : "R";
}

/// `2026-07-20T09:32:11Z` → `07-20 09:32`, in local time (the same clock the
/// hold was recorded against).
function holdStamp(iso: string): string {
  const d = new Date(iso);
  if (isNaN(d.getTime())) return iso;
  const p = (n: number) => String(n).padStart(2, "0");
  return `${p(d.getMonth() + 1)}-${p(d.getDate())} ${p(d.getHours())}:${p(d.getMinutes())}`;
}

function HoldList({
  holds,
  showTag,
}: {
  holds: ZoneHold<TindeqRecordingMeta>[];
  showTag?: boolean;
}) {
  return (
    <div style={{ marginTop: 6, marginLeft: 14 }}>
      {holds.map((h) => {
        const origin = holdOrigin(h.rec);
        const side = sideLabel(h.rec.side);
        return (
          <div
            key={h.rec.id}
            style={{
              display: "flex",
              justifyContent: "space-between",
              gap: 8,
              fontSize: "var(--t-2xs)",
              color: "var(--ink-muted)",
              padding: "2px 0",
            }}
          >
            <span style={{ minWidth: 0, overflow: "hidden", textOverflow: "ellipsis", whiteSpace: "nowrap" }}>
              {holdStamp(h.rec.recordedAt)}
              {showTag && h.rec.tag ? ` · ${h.rec.tag}` : ""}
              {side ? ` · ${side}` : ""}
            </span>
            {/* "recorded" or the duration band it was inferred from (#259). */}
            <span style={{ flexShrink: 0, color: "var(--ink)" }}>
              {fmt1(h.durationS)}s{origin.short ? ` · ${origin.short}` : ""}
            </span>
          </div>
        );
      })}
    </div>
  );
}

function ZoneRow({
  zone,
  holds,
  totalHoldS,
  setDurationS,
  sets,
  holdCount,
  holdS,
  recordedCount,
  inferredCount,
  showTag,
}: {
  zone: TrainingQuality;
  holds: ZoneHold<TindeqRecordingMeta>[];
  totalHoldS: number;
  setDurationS: number;
  sets: number;
  holdCount: number;
  holdS: number;
  recordedCount: number;
  inferredCount: number;
  showTag?: boolean;
}) {
  const [open, setOpen] = useState(false);
  const color = QUALITY_COLORS[zone];
  const label = QUALITIES.find((q) => q.id === zone)!.label;

  return (
    <div style={{ marginBottom: 10 }}>
      <div style={{ display: "flex", alignItems: "baseline", gap: 7 }}>
        <span
          style={{
            width: 8,
            height: 8,
            borderRadius: 4,
            background: color,
            flexShrink: 0,
            alignSelf: "center",
          }}
        />
        <span style={{ fontSize: "var(--t-sm)", fontWeight: 700, color: "var(--ink)", flex: 1 }}>
          {label}
        </span>
        <span style={{ fontSize: "var(--t-sm)", color, fontWeight: 700 }}>
          {fmt1(sets)} set{fmt1(sets) === "1.0" ? "" : "s"}
        </span>
      </div>
      {/* The division itself — the number above is this line's result, not an
          assertion the reader has to take on trust (#214). */}
      <div
        style={{
          fontSize: "var(--t-2xs)",
          color: "var(--ink-muted)",
          marginLeft: 15,
          marginTop: 2,
          lineHeight: 1.5,
        }}
      >
        {holds.length === 0 ? (
          "No holds in this band"
        ) : (
          <>
            {fmt1(totalHoldS)}s of holds ÷ {setDurationS}s per set ({holdS}s ×{" "}
            {holdCount} holds) = {fmt1(sets)}
          </>
        )}
      </div>
      {/* #259: where these holds' zone came from. Only shown once at least
          one hold carries its own — with none, everything here is inferred
          and the caveat at the foot of the panel already says so. */}
      {recordedCount > 0 && (
        <div
          style={{
            fontSize: "var(--t-2xs)",
            color: "var(--ink-faint)",
            marginLeft: 15,
            marginTop: 2,
          }}
        >
          {recordedCount} recorded as {label}
          {inferredCount > 0
            ? ` · ${inferredCount} inferred from hold length`
            : ""}
        </div>
      )}
      {holds.length > 0 && (
        <>
          <button
            onClick={() => setOpen((v) => !v)}
            style={{
              marginLeft: 15,
              marginTop: 3,
              padding: 0,
              background: "none",
              border: "none",
              color: "var(--ink-faint)",
              fontSize: "var(--t-2xs)",
              fontFamily: "inherit",
              cursor: "pointer",
            }}
          >
            {open ? "▾" : "▸"} {holds.length} hold{holds.length === 1 ? "" : "s"}
          </button>
          {open && <HoldList holds={holds} showTag={showTag} />}
        </>
      )}
    </div>
  );
}

/// #214 — "show the working" for a set of holds: for every zone, the hold
/// seconds that fed it, the divisor from ZONE_PROTOCOLS, the division, and
/// (on demand) every contributing hold with its date, duration and band. Used
/// both by the Training-balance detail page and by a Tindeq session in
/// History, so "why this zone" reads the same in both places.
export default function ZoneBreakdownPanel({ recs, showTag }: Props) {
  const { zones, unclassified, excluded } = zoneBreakdown(recs);
  const excludedSummary = ["Warm-up", "Prehab"]
    .map((label) => {
      const count = excluded.filter((h) => holdOrigin(h.rec).label === label).length;
      return count > 0 ? `${count} ${label} hold${count === 1 ? "" : "s"}` : null;
    })
    .filter((part): part is string => part !== null)
    .join(" · ");

  return (
    <div>
      {QUALITIES.map((q) => {
        const e = zones[q.id];
        const zp = ZONE_PROTOCOLS[q.id];
        return (
          <ZoneRow
            key={q.id}
            zone={q.id}
            holds={e.holds}
            totalHoldS={e.totalHoldS}
            setDurationS={e.setDurationS}
            sets={e.sets}
            holdS={zp.holdS}
            // #320: endurance's set length is holdS × reps × sets (8 holds,
            // not zp.reps's 1) — divide back out of setDurationS so the
            // identity shown (holdS × count = setDurationS) stays true for
            // every zone instead of drifting for endurance alone.
            holdCount={e.setDurationS / zp.holdS}
            recordedCount={e.recordedCount}
            inferredCount={e.inferredCount}
            showTag={showTag}
          />
        );
      })}

      {unclassified.length > 0 && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 2 }}>
          {unclassified.length} hold{unclassified.length === 1 ? "" : "s"} under
          1s counted toward nothing (stray blips)
        </div>
      )}

      {/* Maintenance holds are recorded outside training balance BY DESIGN —
          said outright rather than lumped in with the blip line above. */}
      {excluded.length > 0 && (
        <div style={{ fontSize: "var(--t-2xs)", color: "var(--ink-faint)", marginTop: 2 }}>
          {excludedSummary} recorded outside training balance
        </div>
      )}

      {/* The bands, verbatim, with the code's own caveat about them. */}
      <div
        style={{
          marginTop: 12,
          paddingTop: 10,
          borderTop: "1px solid var(--hairline)",
        }}
      >
        <div className="label-eyebrow" style={{ marginBottom: 6 }}>
          How a hold gets its zone
        </div>
        {ZONE_BANDS.map((b) => (
          <div
            key={b.zone}
            style={{
              display: "flex",
              justifyContent: "space-between",
              fontSize: "var(--t-2xs)",
              color: "var(--ink-muted)",
              padding: "2px 0",
            }}
          >
            <span>
              <span style={{ color: QUALITY_COLORS[b.zone] }}>
                {QUALITIES.find((q) => q.id === b.zone)!.label}
              </span>{" "}
              · anchor hold {b.anchorS}s
            </span>
            <span style={{ color: "var(--ink)" }}>{b.band}</span>
          </div>
        ))}
        <div
          style={{
            fontSize: "var(--t-2xs)",
            color: "var(--ink-faint)",
            lineHeight: 1.6,
            marginTop: 8,
          }}
        >
          {ZONE_BAND_CAVEAT}
        </div>
      </div>
    </div>
  );
}
