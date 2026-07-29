import { useState } from "react";
import type { TindeqRecordingMeta } from "../types";
import Sheet from "./Sheet";
import ZoneBreakdownPanel from "./ZoneBreakdownPanel";

interface Props {
  zoneLabel: string;
  recs: TindeqRecordingMeta[];
  /// Defaults false; exists purely so a static-markup test can render the
  /// open state without simulating a click.
  defaultOpen?: boolean;
}

/// #292: the #214 "why this session is [ZONE]" explainer used to render
/// inline, permanently, above every Tindeq session's recordings. It now
/// lives behind a small "?" trigger, matching the app's `InfoDot` "?" →
/// `Sheet` pattern — but its content (a live zone label + this session's own
/// recordings) is dynamic, not the static per-topic copy `InfoDot` serves, so
/// it's a small dedicated trigger rather than a new `InfoDot` API shape.
export default function WhyZoneInfo({ zoneLabel, recs, defaultOpen = false }: Props) {
  const [open, setOpen] = useState(defaultOpen);

  return (
    // display:contents + stopPropagation: this sits inside a Tindeq session's
    // detail page, itself reached through a tappable row — nothing here,
    // including the sheet's Close/backdrop clicks, may bubble back into it.
    <span style={{ display: "contents" }} onClick={(e) => e.stopPropagation()}>
      <div
        style={{
          display: "flex",
          alignItems: "center",
          gap: 7,
          marginBottom: 10,
        }}
      >
        <span className="label-eyebrow">Why this session is {zoneLabel}</span>
        <button
          aria-label={`About: why this session is ${zoneLabel}`}
          onClick={() => setOpen(true)}
          style={{
            width: 18,
            height: 18,
            borderRadius: "50%",
            border: "1px solid var(--border)",
            background: "transparent",
            color: "var(--ink-faint)",
            fontSize: "var(--t-xs)",
            lineHeight: 1,
            cursor: "pointer",
            display: "inline-flex",
            alignItems: "center",
            justifyContent: "center",
            padding: 0,
            fontFamily: "Inter, sans-serif",
            flexShrink: 0,
          }}
        >
          ?
        </button>
      </div>
      {open && (
        <Sheet onClose={() => setOpen(false)}>
          {/* The trigger sits inside an uppercase eyebrow label — undo any
              inherited text styling for the sheet body (same reset as
              InfoDot). */}
          <div style={{ textTransform: "none", letterSpacing: "normal", textAlign: "left" }}>
            <div
              style={{
                fontFamily: "Inter, sans-serif",
                fontSize: "var(--t-lg)",
                fontWeight: 800,
                marginBottom: 12,
              }}
            >
              Why this session is {zoneLabel}
            </div>
            <div
              style={{
                fontSize: "var(--t-2xs)",
                color: "var(--ink-muted)",
                lineHeight: 1.6,
                marginBottom: 10,
              }}
            >
              This session alone, all exercises in it — not the
              trailing-4-week, one-exercise window the Force tab’s Training
              balance card counts.
            </div>
            <ZoneBreakdownPanel recs={recs} showTag />
            <div style={{ marginTop: 14 }}>
              <button className="btn-ghost" onClick={() => setOpen(false)}>
                Close
              </button>
            </div>
          </div>
        </Sheet>
      )}
    </span>
  );
}
