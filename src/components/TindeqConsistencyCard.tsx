import ChartTooltip from "./ChartTooltip";
import InfoDot from "./InfoDot";
import { useCancellableFetch } from "../hooks/useCancellableFetch";
import { useChartHover } from "../hooks/useChartHover";
import { useRealtimeVersion } from "../hooks/useRealtimeVersion";
import { computeTindeqWeeks, selectedTagDays } from "../lib/tindeqConsistency";
import { fetchHiddenTags, fetchRecordings } from "../lib/repo";
import { useState } from "react";
import type { TindeqRecordingMeta } from "../types";

/// Weekly Tindeq-training consistency (#311): "have I been training
/// consistently" is a distinct-days question, not a volume one — see
/// computeTindeqWeeks for why bar height is days trained, not rep count, and
/// why a stacked-by-tag bar would double-count a day carrying two tags. The
/// tag filter narrows the SAME bars to one exercise instead of stacking.
export default function TindeqConsistencyCard() {
  const realtimeVersion = useRealtimeVersion();
  const recordings = useCancellableFetch<TindeqRecordingMeta[] | null>(
    fetchRecordings,
    null,
    realtimeVersion,
  );
  const hiddenTags = useCancellableFetch<string[]>(fetchHiddenTags, [], realtimeVersion);
  const [selectedTag, setSelectedTag] = useState<string | null>(null);
  const [hoveredWeek, hoverWeekProps] = useChartHover<number>();

  // `recordings === null` means "not fetched yet" — must not render as
  // "empty" (CLAUDE.md convention). Computing off `[]` in that case keeps
  // the tag chips and chart hidden below without a separate loading branch.
  const loaded = recordings !== null;
  const { weeks, tags } = computeTindeqWeeks(recordings ?? [], hiddenTags);
  // A selection can go stale (hidden, or aged out of the 8-week window on a
  // realtime refetch) without an explicit `setSelectedTag(null)` — derive the
  // active tag instead of syncing state in an effect, so a stale selection
  // never filters to an all-zero chart with no chip highlighted.
  const activeTag = selectedTag !== null && tags.includes(selectedTag) ? selectedTag : null;
  const barDays = weeks.map((w) => selectedTagDays(w, activeTag));
  const hasAny = weeks.some((w) => w.days > 0);

  return (
    <div className="card">
      <div
        className="card-title"
        style={{ marginBottom: 12, display: "flex", alignItems: "center", gap: 6 }}
      >
        <span>Tindeq consistency</span>
        <InfoDot topic="tindeqConsistency" />
      </div>

      {tags.length > 0 && (
        <div style={{ display: "flex", gap: 6, flexWrap: "wrap", marginBottom: 12 }}>
          <button
            onClick={() => setSelectedTag(null)}
            style={{
              padding: "4px 10px",
              borderRadius: 999,
              fontSize: "var(--t-xs)",
              fontWeight: 600,
              cursor: "pointer",
              border: `1px solid ${activeTag === null ? "var(--info)" : "var(--border)"}`,
              background: activeTag === null ? "rgba(123,131,235,0.12)" : "transparent",
              color: activeTag === null ? "var(--ink)" : "var(--ink-muted)",
            }}
          >
            All
          </button>
          {tags.map((t) => (
            <button
              key={t}
              onClick={() => setSelectedTag(t)}
              style={{
                padding: "4px 10px",
                borderRadius: 999,
                fontSize: "var(--t-xs)",
                fontWeight: 600,
                cursor: "pointer",
                border: `1px solid ${activeTag === t ? "var(--info)" : "var(--border)"}`,
                background: activeTag === t ? "rgba(123,131,235,0.12)" : "transparent",
                color: activeTag === t ? "var(--ink)" : "var(--ink-muted)",
              }}
            >
              {t}
            </button>
          ))}
        </div>
      )}

      {loaded && !hasAny && (
        <div style={{ fontSize: "var(--t-xs)", color: "var(--ink-faint)" }}>
          No Tindeq recordings in the last 8 weeks
        </div>
      )}

      {loaded && hasAny && (
        <div
          className="chart-scrub"
          style={{ display: "flex", gap: 6, alignItems: "flex-end", height: 88 }}
        >
          {weeks.map((w, i) => {
            const days = barDays[i]!;
            const tagLines = activeTag
              ? []
              : Object.entries(w.byTag).sort((a, b) => b[1] - a[1]);
            return (
              <div
                key={i}
                style={{
                  flex: 1,
                  position: "relative",
                  display: "flex",
                  flexDirection: "column",
                  alignItems: "center",
                  gap: 4,
                  height: "100%",
                  justifyContent: "flex-end",
                }}
                {...hoverWeekProps(i)}
              >
                {hoveredWeek === i && (
                  <ChartTooltip
                    align={i < 2 ? "start" : i > weeks.length - 3 ? "end" : "center"}
                  >
                    <div style={{ fontWeight: 600 }}>{w.label}</div>
                    <div style={{ color: "var(--ink-muted)" }}>
                      {days} {days === 1 ? "day" : "days"} trained
                    </div>
                    {tagLines.map(([tag, count]) => (
                      <div key={tag} style={{ color: "var(--ink-muted)" }}>
                        {tag}: {count}
                      </div>
                    ))}
                  </ChartTooltip>
                )}
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-muted)" }}>
                  {days}
                </span>
                <div
                  style={{
                    width: "100%",
                    height: Math.max((days / 7) * 64, 2),
                    background: i === weeks.length - 1 ? "var(--success)" : "var(--border)",
                    borderRadius: 3,
                    opacity: hoveredWeek === null || hoveredWeek === i ? 1 : 0.5,
                    boxShadow: hoveredWeek === i ? "0 0 0 1.5px var(--ink)" : "none",
                    cursor: "pointer",
                    transition: "opacity 0.1s",
                  }}
                />
                <span style={{ fontSize: "var(--t-eyebrow)", color: "var(--ink-faint)" }}>
                  {w.label}
                </span>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
