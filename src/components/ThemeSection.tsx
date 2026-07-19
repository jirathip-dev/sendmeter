import { useState } from "react";

type ThemeChoice = "system" | "light" | "dark";

function currentChoice(): ThemeChoice {
  const explicit = document.documentElement.dataset.theme;
  if (explicit === "light" || explicit === "dark") return explicit;
  return "system";
}

function applyTheme(choice: ThemeChoice) {
  if (choice === "system") {
    delete document.documentElement.dataset.theme;
    localStorage.removeItem("theme");
  } else {
    document.documentElement.dataset.theme = choice;
    localStorage.setItem("theme", choice);
  }
  const isDark =
    choice === "dark" ||
    (choice === "system" &&
      window.matchMedia("(prefers-color-scheme: dark)").matches);
  document
    .querySelector('meta[name="theme-color"]')
    ?.setAttribute("content", isDark ? "#161618" : "#EFEFF1");
}

const OPTIONS: { value: ThemeChoice; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

export default function ThemeSection() {
  const [choice, setChoice] = useState<ThemeChoice>(currentChoice);

  function select(next: ThemeChoice) {
    applyTheme(next);
    setChoice(next);
  }

  return (
    <div>
      <span className="field-label" style={{ marginTop: 0 }}>
        Appearance
      </span>
      <div
        style={{
          display: "flex",
          gap: 4,
          background: "var(--surface-1)",
          border: "1px solid var(--border)",
          borderRadius: 8,
          padding: 3,
        }}
      >
        {OPTIONS.map((o) => (
          <button
            key={o.value}
            onClick={() => select(o.value)}
            style={{
              flex: 1,
              padding: "8px 0",
              borderRadius: 6,
              border: "none",
              cursor: "pointer",
              fontFamily: "Inter, sans-serif",
              fontSize: "var(--t-sm)",
              fontWeight: 600,
              background: choice === o.value ? "var(--canvas)" : "transparent",
              color: choice === o.value ? "var(--ink)" : "var(--ink-muted)",
              boxShadow:
                choice === o.value ? "0 1px 3px rgba(0,0,0,0.15)" : "none",
              transition: "background 0.15s, color 0.15s",
            }}
          >
            {o.label}
          </button>
        ))}
      </div>
    </div>
  );
}
