import { useState } from "react";

function isDarkNow(): boolean {
  const explicit = document.documentElement.dataset.theme;
  if (explicit === "dark") return true;
  if (explicit === "light") return false;
  return window.matchMedia("(prefers-color-scheme: dark)").matches;
}

export default function ThemeToggle() {
  const [dark, setDark] = useState(isDarkNow);

  function toggle() {
    const next = dark ? "light" : "dark";
    document.documentElement.dataset.theme = next;
    localStorage.setItem("theme", next);
    document
      .querySelector('meta[name="theme-color"]')
      ?.setAttribute("content", next === "dark" ? "#161618" : "#EFEFF1");
    setDark(!dark);
  }

  return (
    <button
      onClick={toggle}
      title={dark ? "Switch to light mode" : "Switch to dark mode"}
      style={{
        background: "none",
        border: "none",
        color: "var(--ink-faint)",
        fontSize: 14,
        cursor: "pointer",
        padding: 4,
        lineHeight: 1,
      }}
    >
      {dark ? "☀" : "☾"}
    </button>
  );
}
