import type { TindeqRecordingMeta } from "../types";
import { dateStr, daysAgo } from "./dates";

export interface TindeqWeek {
  label: string;
  days: number;
  byTag: Record<string, number>;
}

export interface TindeqConsistency {
  weeks: TindeqWeek[];
  tags: string[];
}

/// Weekly Tindeq-training consistency (#311): bar height is DISTINCT DAYS
/// trained per rolling 7-day window (0–7), not volume or rep count — the
/// issue asks "have I been training consistently", which a rep/session
/// count would let one big day dominate. Per-tag day counts ride along for
/// the tooltip/filter; a recording carrying a tag on a day already counted
/// by another tag still adds 1 to that tag's own count, so `byTag` values
/// can sum to more than `days` on a day with multiple exercises — that's
/// intentional, not double-counting `days` itself.
export function computeTindeqWeeks(
  recs: TindeqRecordingMeta[],
  hiddenTags: string[],
): TindeqConsistency {
  const hidden = new Set(hiddenTags);
  const visible = recs.filter((r) => !hidden.has(r.tag));
  const windowStart = daysAgo(7 * 7 + 6);
  const tags = [
    ...new Set(
      visible
        .filter((r) => dateStr(new Date(r.recordedAt)) >= windowStart)
        .map((r) => r.tag),
    ),
  ].sort();

  const weeks = [7, 6, 5, 4, 3, 2, 1, 0].map((wb) => {
    const start = daysAgo(wb * 7 + 6);
    const end = daysAgo(wb * 7);
    const allDays = new Set<string>();
    const daysByTag = new Map<string, Set<string>>();
    for (const r of visible) {
      const date = dateStr(new Date(r.recordedAt));
      if (date < start || date > end) continue;
      allDays.add(date);
      let s = daysByTag.get(r.tag);
      if (!s) {
        s = new Set();
        daysByTag.set(r.tag, s);
      }
      s.add(date);
    }
    const byTag: Record<string, number> = {};
    for (const [tag, dates] of daysByTag) byTag[tag] = dates.size;
    return { label: wb === 0 ? "Now" : `${wb}w`, days: allDays.size, byTag };
  });

  return { weeks, tags };
}

/// The single source for "how many days does this week represent" —
/// used for both the bar height/number AND the tooltip headline, so the two
/// can't disagree the way they did pre-#311-fix (tooltip read the unfiltered
/// `week.days` while the bar read the tag-filtered count).
export function selectedTagDays(week: TindeqWeek, selectedTag: string | null): number {
  return selectedTag ? (week.byTag[selectedTag] ?? 0) : week.days;
}
