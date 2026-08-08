/* eslint-disable react-refresh/only-export-components -- the DEV entry exports its mount adapter. */

import { StrictMode, useEffect, useMemo, useState } from "react";
import { createRoot, type Root } from "react-dom/client";
import ConfirmDialog from "../components/ConfirmDialog";
import ChartDefs from "../components/ChartDefs";
import Sheet, { SheetLayerProvider } from "../components/Sheet";
import { useChartHover } from "../hooks/useChartHover";
import {
  CHART_GRADIENTS,
  CHART_TOUCH_TARGET_UNITS,
  chartColor,
  chartGradientUrl,
  chartInstanceId,
} from "../lib/chartTheme";
import {
  createThemeController,
  type ThemeChoice,
  type ThemeController,
} from "../lib/theme";
import "./uiQa.css";

const CHART_WIDTH = 520;
const CHART_HEIGHT = 180;
const CHART_VALUES: readonly number[] = [34, 41, 38, 47, 44, 52, 49, 58, 55];
const SHEET_ROWS = [
  ["Warm-up", "Eight minutes of easy movement before loading the fingers."],
  ["Readiness context", "Static health inputs keep this surface repeatable in every review."],
  ["Load context", "The compact load story stays visible beside the selected force point."],
  ["Force context", "Scrub across the curve to exercise the shared chart interaction seam."],
  ["History context", "A long body verifies that the header stays put while the sheet scrolls."],
  ["Recovery note", "No account, network, or repository state is needed for this fixture."],
  ["Next step", "Open the nested confirmation to inspect stacking and scroll locking together."],
] as const;
const THEME_OPTIONS = [
  { value: "system", label: "System", testId: "uiqa-theme-system" },
  { value: "light", label: "Light", testId: "uiqa-theme-light" },
  { value: "dark", label: "Dark", testId: "uiqa-theme-dark" },
] as const;

function embeddedSource(): string {
  const url = new URL(window.location.href);
  url.search = "?ui-qa&embedded=1";
  url.hash = "";
  return url.toString();
}

function UiQaOuter() {
  const src = embeddedSource();
  return (
    <main className="uiqa-outer" data-testid="uiqa-outer">
      <header className="uiqa-outer-header">
        <div>
          <p className="uiqa-kicker">Sendmeter · internal tooling</p>
          <h1>UI-QA-LAB</h1>
          <p className="uiqa-outer-copy">
            Deterministic phone surfaces for sheets, charts, themes, and scroll
            locks.
          </p>
        </div>
        <span className="uiqa-dev-pill">DEV ONLY</span>
      </header>
      <section className="uiqa-frame-grid" aria-label="Phone viewport controls">
        <div className="uiqa-frame-control">
          <div className="uiqa-frame-label">
            <strong>390 × 844</strong>
            <span>standard phone</span>
          </div>
          <iframe
            data-testid="uiqa-frame-390x844"
            title="Sendmeter UI QA lab at 390 by 844"
            src={src}
            width={390}
            height={844}
          />
        </div>
        <div className="uiqa-frame-control">
          <div className="uiqa-frame-label">
            <strong>375 × 667</strong>
            <span>compact phone</span>
          </div>
          <iframe
            data-testid="uiqa-frame-375x667"
            title="Sendmeter UI QA lab at 375 by 667"
            src={src}
            width={375}
            height={667}
          />
        </div>
      </section>
    </main>
  );
}

function MetricCard({
  testId,
  className,
  label,
  value,
  detail,
}: {
  testId: string;
  className: string;
  label: string;
  value: string;
  detail: string;
}) {
  return (
    <article className={`card uiqa-metric-card ${className}`} data-testid={testId}>
      <span className="label-eyebrow">{label}</span>
      <strong className="uiqa-metric-value">{value}</strong>
      <span className="uiqa-metric-detail">{detail}</span>
    </article>
  );
}

function ForceScrubChart() {
  const [selected, , , surfaceProps] = useChartHover<number>();
  const chartId = useMemo(() => chartInstanceId("uiqa", "force-scrub"), []);
  const points = CHART_VALUES.map((value, index) => {
    const x = 18 + index * ((CHART_WIDTH - 36) / (CHART_VALUES.length - 1));
    const y = CHART_HEIGHT - 24 - ((value - 28) / 34) * (CHART_HEIGHT - 52);
    return { x, y, value };
  });
  const linePoints = points.map(({ x, y }) => `${x},${y}`).join(" ");
  const areaPath = `M ${points[0]!.x} ${CHART_HEIGHT - 20} L ${points
    .map(({ x, y }) => `${x} ${y}`)
    .join(" L ")} L ${points[points.length - 1]!.x} ${CHART_HEIGHT - 20} Z`;
  const selectedIndex = selected === null ? -1 : CHART_VALUES.indexOf(selected);
  const selectedPoint = selectedIndex < 0 ? null : points[selectedIndex];
  const selectedLabel = selected === null ? "No point selected" : `${selected} kg selected`;

  return (
    <section className="card uiqa-chart-card" aria-labelledby="uiqa-chart-title">
      <div className="uiqa-section-heading">
        <div>
          <span className="label-eyebrow">Force trend</span>
          <h2 id="uiqa-chart-title">Horizontal scrub</h2>
        </div>
        <output data-testid="uiqa-chart-selection" aria-live="polite">
          {selectedLabel}
        </output>
      </div>
      <div className="uiqa-chart-viewport">
        <svg
          className="uiqa-chart"
          width={CHART_WIDTH}
          height={CHART_HEIGHT}
          viewBox={`0 0 ${CHART_WIDTH} ${CHART_HEIGHT}`}
          role="img"
          aria-label="Static force trend chart"
        >
          <ChartDefs instanceId={chartId} />
          <line
            x1="0"
            x2={CHART_WIDTH}
            y1={CHART_HEIGHT - 20}
            y2={CHART_HEIGHT - 20}
            stroke={chartColor("grid")}
            strokeWidth="1"
          />
          <path
            d={areaPath}
            fill={chartGradientUrl(chartId, CHART_GRADIENTS.forceArea)}
            stroke="none"
          />
          <polyline
            points={linePoints}
            fill="none"
            stroke={chartColor("force")}
            strokeWidth="3"
            strokeLinecap="round"
            strokeLinejoin="round"
          />
          {selectedPoint && (
            <line
              x1={selectedPoint.x}
              x2={selectedPoint.x}
              y1="12"
              y2={CHART_HEIGHT - 20}
              stroke={chartColor("reference")}
              strokeDasharray="3 4"
            />
          )}
          <rect
            className="chart-scrub"
            data-testid="uiqa-chart-hit-surface"
            x="0"
            y="0"
            width={CHART_WIDTH}
            height={Math.max(CHART_HEIGHT, CHART_TOUCH_TARGET_UNITS)}
            fill="transparent"
            role="slider"
            tabIndex={0}
            aria-label="Scrub the force trend"
            aria-valuemin={CHART_VALUES[0]}
            aria-valuemax={CHART_VALUES[CHART_VALUES.length - 1]}
            aria-valuenow={selected ?? CHART_VALUES[0]}
            {...surfaceProps(
              CHART_VALUES,
              CHART_WIDTH,
              (index) => points[index]!.x,
            )}
          />
        </svg>
      </div>
      <p className="uiqa-chart-help">Drag left or right, or use the arrow keys.</p>
    </section>
  );
}

function ThemeControls({
  choice,
  onSelect,
}: {
  choice: ThemeChoice;
  onSelect: (choice: ThemeChoice) => void;
}) {
  return (
    <section className="card uiqa-theme-card" aria-labelledby="uiqa-theme-title">
      <div className="uiqa-section-heading">
        <div>
          <span className="label-eyebrow">Appearance</span>
          <h2 id="uiqa-theme-title">Theme controller</h2>
        </div>
        <span className="uiqa-theme-current">{choice}</span>
      </div>
      <div className="uiqa-theme-options">
        {THEME_OPTIONS.map((option) => (
          <button
            key={option.value}
            type="button"
            className={`theme-option${choice === option.value ? " selected" : ""}`}
            data-testid={option.testId}
            aria-pressed={choice === option.value}
            onClick={() => onSelect(option.value)}
          >
            {option.label}
          </button>
        ))}
      </div>
    </section>
  );
}

function UiQaEmbedded() {
  const [sheetOpen, setSheetOpen] = useState(false);
  const [confirmOpen, setConfirmOpen] = useState(false);
  const [actionMessage, setActionMessage] = useState("Ready for a deterministic pass.");
  const [themeController] = useState<ThemeController>(() => createThemeController());
  const [themeChoice, setThemeChoice] = useState<ThemeChoice>(() =>
    themeController.initialize(),
  );

  useEffect(() => () => themeController.dispose(), [themeController]);

  function selectTheme(choice: ThemeChoice): void {
    themeController.setChoice(choice);
    setThemeChoice(choice);
  }

  function closeSheet(): void {
    setConfirmOpen(false);
    setSheetOpen(false);
  }

  const locked = sheetOpen || confirmOpen;

  return (
    <SheetLayerProvider layer="default">
      <div className="uiqa-phone-frame app-shell" data-testid="uiqa-phone-frame">
        <header className="uiqa-phone-header">
          <div>
            <p className="uiqa-kicker">Sendmeter</p>
            <h1>UI-QA-LAB</h1>
          </div>
          <div className="uiqa-lock-probe">
            <span>Scroll lock</span>
            <output data-testid="uiqa-lock-status" data-locked={locked}>
              {locked ? "LOCKED" : "OPEN"}
            </output>
          </div>
        </header>

        <div className="content-area uiqa-content">
          <section className="uiqa-intro" aria-labelledby="uiqa-intro-title">
            <span className="label-eyebrow">Deterministic fixture</span>
            <h2 id="uiqa-intro-title">A small surface with the real seams</h2>
            <p>
              Static cards keep visual QA focused while the production sheet,
              chart, theme, and lock primitives do the work underneath.
            </p>
          </section>

          <div className="uiqa-metric-grid">
            <MetricCard
              testId="uiqa-readiness-card"
              className="surface-readiness"
              label="Readiness"
              value="82"
              detail="Strong · static overnight signal"
            />
            <MetricCard
              testId="uiqa-load-card"
              className="surface-load"
              label="Training load"
              value="0.78"
              detail="ACWR · steady working week"
            />
            <MetricCard
              testId="uiqa-force-card"
              className="surface-force"
              label="Force PR"
              value="42.6 kg"
              detail="Right side · 3 reps"
            />
            <MetricCard
              testId="uiqa-history-card"
              className="surface-history"
              label="History"
              value="Yesterday"
              detail="Fingerboard · 45 minutes"
            />
          </div>

          <ForceScrubChart />

          <ThemeControls choice={themeChoice} onSelect={selectTheme} />

          <section className="card uiqa-actions-card" aria-labelledby="uiqa-actions-title">
            <div className="uiqa-section-heading">
              <div>
                <span className="label-eyebrow">Interaction states</span>
                <h2 id="uiqa-actions-title">Actions</h2>
              </div>
              <span className="uiqa-action-message" aria-live="polite">
                {actionMessage}
              </span>
            </div>
            <div className="uiqa-action-stack">
              <button
                type="button"
                className="btn-primary"
                data-testid="uiqa-open-sheet"
                onClick={() => setSheetOpen(true)}
              >
                Open detail sheet
              </button>
              <button
                type="button"
                className="btn-primary"
                data-testid="uiqa-primary-action"
                onClick={() => setActionMessage("Primary action checked.")}
              >
                Primary action
              </button>
              <button
                type="button"
                className="btn-secondary"
                data-testid="uiqa-secondary-action"
                onClick={() => setActionMessage("Secondary action checked.")}
              >
                Secondary action
              </button>
              <button
                type="button"
                className="btn-danger"
                data-testid="uiqa-danger-action"
                onClick={() => setActionMessage("Danger action is wired safely.")}
              >
                Danger action
              </button>
              <button
                type="button"
                className="btn-primary"
                data-testid="uiqa-disabled-action"
                disabled
              >
                Disabled action
              </button>
            </div>
          </section>

          <div className="uiqa-scroll-sentinel" data-testid="uiqa-scroll-sentinel">
            Background scroll sentinel · bottom of the fixture
          </div>
        </div>

        {sheetOpen && (
          <Sheet
            title="Detail sheet"
            subtitle="Real production sheet · long body · nested confirm"
            fullHeight
            className="uiqa-sheet-proof"
            onClose={closeSheet}
          >
            <div className="uiqa-sheet-body">
              <p className="uiqa-sheet-lede">
                The header is a separate non-scrolling region. The close control
                remains a 44px target while this body moves underneath it.
              </p>
              <button
                type="button"
                className="btn-secondary"
                data-testid="uiqa-open-confirm"
                onClick={() => setConfirmOpen(true)}
              >
                Open nested confirm
              </button>
              {SHEET_ROWS.map(([title, body], index) => (
                <article className="uiqa-sheet-row" key={title}>
                  <span className="label-eyebrow">0{index + 1}</span>
                  <div>
                    <h3>{title}</h3>
                    <p>{body}</p>
                  </div>
                </article>
              ))}
              <div
                className="uiqa-sheet-scroll-sentinel"
                data-testid="uiqa-sheet-scroll-sentinel"
              >
                Sheet scroll sentinel · end of the long body
              </div>
            </div>
          </Sheet>
        )}

        {confirmOpen && (
          <ConfirmDialog
            title="Confirm fixture action"
            body="This nested confirmation is static and never changes app data."
            confirmLabel="Confirm"
            cancelLabel="Keep sheet open"
            danger
            onConfirm={() => {
              setActionMessage("Nested confirmation checked.");
              setConfirmOpen(false);
            }}
            onClose={() => setConfirmOpen(false)}
          />
        )}
      </div>
    </SheetLayerProvider>
  );
}

export function mountUiQa(root: HTMLElement): Root {
  const embedded = new URLSearchParams(window.location.search).get("embedded") === "1";
  const reactRoot = createRoot(root);
  reactRoot.render(
    <StrictMode>{embedded ? <UiQaEmbedded /> : <UiQaOuter />}</StrictMode>,
  );
  return reactRoot;
}
