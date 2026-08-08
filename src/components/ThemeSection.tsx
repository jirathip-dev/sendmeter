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
    ?.setAttribute("content", isDark ? "#0E121B" : "#F2F4F8");
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
      <div className="theme-switcher">
        {OPTIONS.map((o) => (
          <button
            key={o.value}
            type="button"
            className={`theme-option${choice === o.value ? " selected" : ""}`}
            aria-pressed={choice === o.value}
            onClick={() => select(o.value)}
          >
            {o.label}
          </button>
        ))}
      </div>
    </div>
  );
}
