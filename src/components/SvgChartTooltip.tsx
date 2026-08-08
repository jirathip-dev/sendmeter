/// Tooltip for SVG point/line charts, drawn in the same viewBox coordinate
/// space as the chart itself (avoids converting between viewBox units and
/// screen pixels for a responsive, scaled SVG). Clamped to stay inside the
/// viewBox and flips below the point if there's no room above.
export default function SvgChartTooltip({
  x,
  y,
  viewW,
  viewH,
  lines,
}: {
  x: number;
  y: number;
  viewW: number;
  viewH: number;
  lines: string[];
}) {
  const lineH = 10;
  const padX = 5;
  const padY = 4;
  const boxW = Math.max(...lines.map((l) => l.length)) * 4.6 + padX * 2;
  const boxH = lines.length * lineH + padY * 2 - 2;

  let bx = x - boxW / 2;
  bx = Math.max(2, Math.min(bx, viewW - boxW - 2));

  let by = y - boxH - 8;
  if (by < 2) by = Math.min(y + 10, viewH - boxH - 2);

  return (
    <g role="status" aria-live="polite" style={{ pointerEvents: "none" }}>
      <rect
        x={bx}
        y={by}
        width={boxW}
        height={boxH}
        rx={3}
        style={{ fill: "var(--chart-tooltip)", stroke: "var(--chart-tooltip-border)" }}
        strokeWidth={0.6}
      />
      {lines.map((line, i) => (
        <text
          key={i}
          x={bx + padX}
          y={by + padY + 7 + i * lineH}
          fontSize={7.5}
          style={{ fill: "var(--ink)" }}
        >
          {line}
        </text>
      ))}
    </g>
  );
}
