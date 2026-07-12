# Send Log — Design System

Adapted from the Descript design language (dark chrome + white document panels,
blue-violet primary, Inter) and tuned for a **health / performance** product:
your training data is the document. The chrome recedes; white cards carry the
numbers you came to read.

## Core metaphor

Descript's insight — *the transcript IS the edit* — maps here as: **the log IS
the training**. The app shell is a dark professional dashboard (like an editor
or a cockpit); every piece of content — sessions, readiness, force curves —
sits on a white "paper" card, reading like entries in a training journal.
Purple means "this is the signal": the live force trace, the playhead of your
training, primary actions.

## Color tokens (`src/index.css` `:root`)

| Token | Value | Use |
|---|---|---|
| `--chrome` | `#1C1C1E` | App shell: topbar, nav, content background |
| `--chrome-panel` | `#252528` | Raised chrome (nav hover, chrome inputs) |
| `--chrome-ink` | `#E5E5EA` | Text on chrome |
| `--chrome-ink-muted` | `#98989D` | Secondary text on chrome |
| `--chrome-border` | `#3A3A3E` | Hairlines on chrome |
| `--canvas` | `#FFFFFF` | Cards / panels — the "paper" |
| `--surface-1` | `#F5F5F7` | Inputs, inner wells on cards |
| `--surface-2` | `#EBEBED` | Emphasized wells (load preview) |
| `--border` | `#D8D8DC` | Borders on white surfaces |
| `--ink` | `#1C1C1E` | Primary text on white |
| `--ink-muted` | `#6E6E73` | Labels, secondary text on white (AA 5.1:1) |
| `--ink-faint` | `#8E8E93` | Tertiary/metadata on white |
| `--primary` | `#5B5FC7` | CTAs, live force trace ("waveform"), active nav, links |
| `--primary-hover` | `#4A4EB3` | Hover state |
| `--info` | `#7B83EB` | Tags, secondary data series |
| `--success` | `#34C759` | Readiness *Push*, optimal ACWR, positive deltas |
| `--warning` | `#FFB800` | Readiness *Maintain*, ACWR caution, PR markers, CF hints |
| `--danger` | `#FF453A` | Readiness *Recover*, ACWR danger, delete, negative deltas |
| `--orange` | `#FF9500` | Critical-force line, power phase |

**Health-semantic rule:** green / amber / red are reserved for *physiological
state* (readiness zones, ACWR bands, deltas). They never decorate. Purple is
never a health signal — it marks *interaction and live data*. This separation
is the health-app equivalent of Descript's "purple = where the audio is."

### Phase palette (training periodization identity)

| Phase | Color | On-white bg | Border |
|---|---|---|---|
| Capacity | `#34C759` | `rgba(52,199,89,0.10)` | `rgba(52,199,89,0.35)` |
| Strength | `#FFB800` | `rgba(255,184,0,0.10)` | `rgba(255,184,0,0.35)` |
| Power | `#FF9500` | `rgba(255,149,0,0.10)` | `rgba(255,149,0,0.35)` |
| Execution | `#5B5FC7` | `rgba(91,95,199,0.10)` | `rgba(91,95,199,0.35)` |

## Typography

Single family: **Inter** (Google Fonts, weights 400/500/600/700/800).
- **Display / stat numbers**: Inter 800, letter-spacing −0.02em,
  `font-variant-numeric: tabular-nums` — numbers are the product; they must
  align and be scannable (readiness 72, ACWR 1.13, 36.8 kg).
- **UI / body**: Inter 400–500, 13–15px.
- **Labels**: Inter 600, 10px, uppercase, +0.08em tracking, `--ink-muted`.
- The old DM Mono / Syne pairing is retired; where Descript uses Georgia for
  the transcript, we use oversized tabular numerals instead — the "document"
  here is numeric, not prose.

## Surfaces & components

- **Cards** (`.card`, `.session-row`): white, `border-radius: 12px`,
  `box-shadow: 0 1px 4px rgba(0,0,0,0.12)`, no border (border only for inner
  nesting). Cards on chrome need no outline — the value contrast does the work.
- **Buttons**: `.btn-primary` = purple fill, white text, radius 8.
  `.btn-ghost` on chrome = chrome-border + chrome-ink; inside cards it
  inherits a light variant (`.card .btn-ghost`, `.modal-sheet .btn-ghost`).
- **Modals**: white document panels (`.modal-sheet`) — bottom sheet on mobile,
  centered dialog ≥720px. The moment of input = the white paper moment.
- **Charts**: data series in `--primary` purple (the "waveform"), PR points in
  `--warning` amber, CF reference lines in `--orange`, axes/gridlines
  `#E5E5EA`, axis text `#8E8E93`. Canvas/SVG use literal hex (attributes can't
  resolve CSS vars).
- **Live gauge**: purple trace on white; target zone = translucent green band
  (health-semantic: green = where you should be); in-zone force number turns
  `--success`.
- **Tags/chips**: tinted backgrounds at 10% alpha with 35% alpha borders,
  600-weight 9px uppercase text in the accent color.

## Spacing / radius / motion

- Spacing scale: 4 / 8 / 12 / 16 / 24 / 32 / 48. Cards pad 16; content-area
  pads 16 (mobile) / 24–32 (desktop).
- Radius: 8 (inputs/buttons), 12 (cards), 16 (sheets).
- Motion: 100–200ms, `cubic-bezier(0.4, 0, 0.2, 1)`; all transitions wrapped
  in `@media (prefers-reduced-motion: reduce)` suppression.

## Layout

- Mobile: single column, bottom tab bar (chrome), thumb-first.
- Desktop ≥720px: 960px centered shell, horizontal nav under the header with
  purple active underline, `grid-2-desktop` pairs cards, modals centered.

## Accessibility

- `--ink` on white: 17:1 (AAA). `--ink-muted` on white: 5.1:1 (AA).
- `--primary` on white: 5.4:1 (AA) — safe for text links and labels.
- On-chrome text uses `--chrome-ink` (13.9:1) / `--chrome-ink-muted` (7.0:1).
- Focus: 2px `--primary` outline, 2px offset.
- Touch targets ≥ 44px on interactive rows and nav.
- Reduced motion: no animated transitions; live gauge still updates values
  (data updates are content, not decoration).

## What deliberately stayed

- Zone/status colors carry meaning across watch + web + DB (`push/maintain/
  recover`) — hues tuned to this palette but semantics unchanged.
- The boulder app icon and dark PWA identity (`theme-color #1C1C1E`).
- Watch app keeps native watchOS styling; this system governs web + iOS shell.
