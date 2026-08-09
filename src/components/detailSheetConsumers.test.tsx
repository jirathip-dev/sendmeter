// @vitest-environment jsdom
import { act, createElement } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeEach, describe, expect, it, vi } from "vitest";
import type { Session, TindeqRecordingMeta } from "../types";

const repoMocks = vi.hoisted(() => ({
  fetchRecordingsByGroup: vi.fn(),
  fetchSamplesForRecordings: vi.fn(),
  fetchWorkoutForSession: vi.fn(),
  deleteRecording: vi.fn(),
  recalcTindeqSessionDuration: vi.fn(),
}));

vi.mock("../lib/repo", () => repoMocks);

import SessionRow from "./SessionRow";
import ZoneFocusCard from "./ZoneFocusCard";

(globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;

const session: Session = {
  id: "session-1",
  date: "2026-08-08",
  type: "tindeq",
  typeLabel: "Force",
  duration: 12,
  rpe: 6,
  rpeConfirmed: true,
  load: 72,
  note: "",
  phase: "capacity",
  groupId: "group-1",
  workoutSource: null,
};

function recording(over: Partial<TindeqRecordingMeta> = {}): TindeqRecordingMeta {
  return {
    id: "recording-1",
    recordedAt: "2026-08-08T08:00:00.000Z",
    durationMs: 30_000,
    peakKg: 40,
    avgKg: 35,
    sampleCount: 100,
    note: "",
    tag: "FDP",
    side: "left",
    groupId: null,
    protocolRunId: null,
    setNo: null,
    zone: null,
    source: "dynamometer",
    ...over,
  };
}

describe("converted detail-sheet consumers", () => {
  let container: HTMLDivElement;
  let root: Root;

  beforeEach(() => {
    container = document.createElement("div");
    document.body.appendChild(container);
    root = createRoot(container);
    repoMocks.fetchRecordingsByGroup.mockResolvedValue([]);
    repoMocks.fetchSamplesForRecordings.mockResolvedValue(new Map());
    repoMocks.fetchWorkoutForSession.mockResolvedValue(null);
  });

  afterEach(async () => {
    await act(async () => {
      root.unmount();
      await Promise.resolve();
    });
    container.remove();
    vi.clearAllMocks();
    document.body.style.overflow = "";
    document.documentElement.style.overflow = "";
  });

  it("opens History's session detail as a real sheet and dismisses its backdrop", async () => {
    await act(async () => {
      root.render(
        createElement(SessionRow, {
          s: session,
          onDelete: vi.fn(),
        }),
      );
      await Promise.resolve();
    });

    const row = container.querySelector<HTMLElement>(".session-row")!;
    await act(async () => {
      row.click();
      await Promise.resolve();
    });

    const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
    expect(dialog?.querySelector("h2")?.textContent).toBe("Force");
    expect(dialog?.dataset.sheetLayer).toBe("default");
    expect(dialog?.querySelector(".modal-content")?.textContent).toContain(
      "No recordings in this session",
    );

    await act(async () => {
      dialog?.dispatchEvent(new MouseEvent("click", { bubbles: true, cancelable: true }));
      await Promise.resolve();
    });
    expect(document.querySelector('[role="dialog"]')).toBeNull();
    expect(document.body.style.overflow).toBe("");
  });

  it("opens Training balance from its card and closes through the shared control", async () => {
    await act(async () => {
      root.render(
        createElement(ZoneFocusCard, {
          recordings: [recording()],
          exercise: "FDP",
          model: null,
          onPick: vi.fn(),
          locked: false,
        }),
      );
      await Promise.resolve();
    });

    const card = container.querySelector<HTMLElement>(".card.tappable")!;
    expect(card.textContent).toContain("Training balance · FDP");
    await act(async () => {
      card.click();
      await Promise.resolve();
    });

    const dialog = document.querySelector<HTMLElement>('[role="dialog"]');
    expect(dialog?.querySelector("h2")?.textContent).toBe("Training balance");
    expect(dialog?.querySelector(".modal-content")?.textContent).toContain("What this counts");
    expect(dialog?.dataset.sheetTypography).toBe("inter-tabular");

    await act(async () => {
      dialog?.querySelector<HTMLButtonElement>(".modal-close")?.click();
      await Promise.resolve();
    });
    expect(document.querySelector('[role="dialog"]')).toBeNull();
  });
});
