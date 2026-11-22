## Summary

Decision: Add a MoonBoard route from a screenshot in three steps: pick your wall and a screenshot (or paste one), check the holds Sendmeter read on a drawn board beside the screenshot, then save. Holds the reader is unsure of are marked to check, a tap on the board adds, changes or erases a hold, and nothing is saved until you press Save. An unreadable image gets a short reason and saves nothing.
Screens: Pick (wall and screenshot), Check holds (confirm and fix), Can't read (not a MoonBoard, board cut off, other layout).
Open questions: (1) Should the reader also try to read the route's name and grade from the screenshot's text, or leave them to you (drawn: a dated default name, grade empty)? (2) When a Mini screenshot is picked for a full wall and you own a Mini wall, offer "Read on Mini 2020" (drawn) or only "Choose another"?

## Screens

Each page has `png/<page>-390.png` (phone) and `png/<page>-1440.png` (wide: the tab bar becomes #1046's sidebar). Look, board panel and hold colours follow #1046 (`origin/issue-1046`, Board route detail): green start, blue hand, magenta finish, on the Sendmeter tokens in `docs/design/tokens.md`.

| Image | Decision it shows |
|---|---|
| `pick` | Reached from the Board tab's **+** menu as a third choice beside New route and Import. Wall chips list only your MoonBoard walls (the route is read onto that wall's grid). A small drawing shows what a usable screenshot has: the whole board, A–K and 1–18 in view, holds circled. **Choose screenshot** opens the system photo picker, one image only; **Paste** takes a screenshot already copied. "Read on this phone": nothing is uploaded. |
| `confirm` | The holds read, drawn on the chosen wall's lettered grid, with the screenshot as a corner thumbnail on the phone (tap to compare full size) and side by side at 1440. Start / Hand / Finish / Erase picks what a tap on a hole does. The hold list repeats them by role as grid labels; a hold the reader is unsure of has a dashed ring, a "?" and a "1 to check" count, but does not block saving. Name defaults to "Route <date>", grade is optional. **Save** (top right and the button) is the only way anything is stored; Back discards. |
| `error` | One reason per unreadable image, its thumbnail with the problem shown, **Choose another** and a fallback. Phone shows "Not a MoonBoard"; 1440 shows all three cases side by side: not a MoonBoard (no A–K, 1–18 grid), board cut off (the missing rows shaded and named), other layout (12 rows on an 18-row wall, with the matching wall offered if you have one). "Mark holds by hand" opens the normal new-route hold picker. "Nothing saved" under each. |

The screenshots drawn here are Sendmeter's own sketches of a generic board app, not a maker's screen.

## Render

`./render.sh` (all) or `./render.sh confirm` writes `png/`. It uses the Playwright and Chromium already in the host's caches through `render.mjs` (set `PW_CORE` and `CHROME` to override).
