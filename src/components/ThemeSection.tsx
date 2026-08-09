import { useState } from "react";
import {
  currentThemeChoice,
  setThemeChoice,
  type ThemeChoice,
} from "../lib/theme";

const OPTIONS: { value: ThemeChoice; label: string }[] = [
  { value: "system", label: "System" },
  { value: "light", label: "Light" },
  { value: "dark", label: "Dark" },
];

export default function ThemeSection() {
  const [choice, setChoice] = useState<ThemeChoice>(currentThemeChoice);

  function select(next: ThemeChoice) {
    setThemeChoice(next);
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
