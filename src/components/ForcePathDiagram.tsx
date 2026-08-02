import type { ForceMeasurementMode } from "../lib/forceSetup";

export default function ForcePathDiagram({ mode }: { mode: ForceMeasurementMode }) {
  const movement = mode === "movement";
  const title = movement ? "Movement set force path" : "Static hold force path";
  const description = movement
    ? "Fixed anchor, then dynamometer, then a compliant spring, then the handle, all aligned with the pull."
    : "Fixed anchor, then dynamometer, then the handle or edge, all aligned with the pull.";
  const nodes = movement
    ? [
        { x: 45, label: "Fixed\nanchor", kind: "anchor" },
        { x: 145, label: "Force\nsensor", kind: "sensor" },
        { x: 245, label: "Spring /\ncompliance", kind: "spring" },
        { x: 345, label: "Handle", kind: "handle" },
      ]
    : [
        { x: 70, label: "Fixed\nanchor", kind: "anchor" },
        { x: 200, label: "Force\nsensor", kind: "sensor" },
        { x: 330, label: "Handle /\nedge", kind: "handle" },
      ];

  return (
    <figure className="force-path-figure">
      <svg
        viewBox="0 0 400 150"
        role="img"
        aria-labelledby={`force-path-${mode}-title force-path-${mode}-desc`}
      >
        <title id={`force-path-${mode}-title`}>{title}</title>
        <desc id={`force-path-${mode}-desc`}>{description}</desc>
        <defs>
          <marker id={`arrow-${mode}`} viewBox="0 0 10 10" refX="9" refY="5" markerWidth="7" markerHeight="7" orient="auto-start-reverse">
            <path d="M 0 0 L 10 5 L 0 10 z" fill="currentColor" />
          </marker>
        </defs>
        <line x1="30" y1="60" x2="370" y2="60" className="force-path-line" markerEnd={`url(#arrow-${mode})`} />
        {nodes.map((node) => (
          <g key={node.kind} transform={`translate(${node.x} 60)`}>
            {node.kind === "anchor" ? (
              <path d="M-20-24h12v48h-12m12-34h13m-13 20h13" className="force-path-node" />
            ) : node.kind === "spring" ? (
              <path d="M-30 0h8l6-14 12 28 12-28 12 28 6-14h8" className="force-path-node" />
            ) : node.kind === "handle" ? (
              <path d="M-20 8v-13c0-12 40-12 40 0V8M-24 8h48" className="force-path-node" />
            ) : (
              <rect x="-24" y="-16" width="48" height="32" rx="9" className="force-path-sensor" />
            )}
            <text y="44" textAnchor="middle" className="force-path-label">
              {node.label.split("\n").map((line, index) => (
                <tspan key={line} x="0" dy={index === 0 ? 0 : 14}>{line}</tspan>
              ))}
            </text>
          </g>
        ))}
      </svg>
      <figcaption>{description}</figcaption>
    </figure>
  );
}
