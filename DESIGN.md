# Sendmeter — Design System

Adapted from the Descript design language (recessive chrome + document panels,
blue-violet primary, Inter) and tuned for a **health / performance** product:
your training data is the document. The chrome recedes; cards carry the numbers
you came to read.

> **Updated 2026-07 — theme-aware + floating glass chrome.** The app is now
> **light by default + dark** (via `:root[data-theme="dark"]` and a
> `prefers-color-scheme` fallback), so the old fixed dark-`--chrome-*` tokens
> below are superseded by the theme-aware set in [Color tokens](#color-tokens-srcindexcss-root)
> (`--bg`, `--canvas`, `--hairline`, `--card-border`, …). The chrome is no
> longer solid bars — it's **floating glass** (see
> [Floating glass chrome](#floating-glass-chrome--interactions-2026-refresh) at
> the bottom, which is the current source of truth for the app shell).

## Core metaphor

Descript's insight — *the transcript IS the edit* — maps here as: **the log IS
the training**. The app shell is a dark professional dashboard (like an editor
or a cockpit); every piece of content — sessions, readiness, force curves —
sits on a white "paper" card, reading like entries in a training journal.
Purple means "this is the signal": the live force trace, the playhead of your
training, primary actions.

## Color tokens (`src/index.css` `:root`)

Theme-aware: light values are the `:root` default; dark overrides live in
`:root[data-theme="dark"]` and a `@media (prefers-color-scheme: dark)` fallback.
Reference tokens by name — never hardcode hex in components (SVG attributes are
the one exception; they can't resolve CSS vars, so charts use literal hex).

| Token | Light | Dark | Use |
|---|---|---|---|
| `--bg` | `#EFEFF1` | `#161618` | App shell background (behind cards, under safe areas) |
| `--canvas` | `#FFFFFF` | `#232327` | Cards / panels — the "paper"; also the glass tint base |
| `--card-border` | `transparent` | `#303034` | Card outline (dark only) |
| `--surface-1` | `#F5F5F7` | `#2C2C31` | Inputs, inner wells on cards |
| `--surface-2` | `#E9E9EC` | `#37373C` | Emphasized wells; heatmap empty cell |
| `--border` | `#D8D8DC` | `#3E3E44` | Borders on surfaces |
| `--hairline` | `#E2E2E6` | `#333338` | Dividers, gridlines |
| `--ink` | `#1C1C1E` | `#E8E8EC` | Primary text |
| `--ink-muted` | `#6E6E73` | `#A9A9B0` | Labels, secondary text |
| `--ink-faint` | `#8E8E93` | `#7F7F87` | Tertiary/metadata, axis text |
| `--primary` | `#5B5FC7` | `#5B5FC7` | CTAs, live force trace, active state, data series |
| `--primary-hover` | `#4A4EB3` | `#6A6ED6` | Hover state |
| `--primary-accent` | `#5B5FC7` | `#9296EE` | Primary used as text/underline (readable on the theme bg) |
| `--info` | `#7B83EB` | `#7B83EB` | Tags, secondary data series |
| `--success` | `#34C759` | Readiness *Push*, optimal ACWR, heatmap load, positive deltas |
| `--warning` | `#FFB800` | Readiness *Maintain*, ACWR caution, PR markers |
| `--danger` | `#FF453A` | Readiness *Recover*, ACWR danger, delete, negative deltas |
| `--orange` | `#FF9500` | Critical-force line, power phase |
| `--shadow-card` / `--overlay` | — | — | Card shadow / modal backdrop (theme-tuned) |

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
- The boulder app icon and the PWA identity (`theme-color` = `#EFEFF1` light /
  `#161618` dark).
- Watch app keeps native watchOS styling; this system governs web + iOS shell.

---

# Floating glass chrome & interactions (2026 refresh)

The app shell moved from solid bars to **floating glass** that gets out of the
way. There is no full-width header anymore — just a circular account button —
and the bottom nav is a translucent pill that auto-hides on scroll. This section
is the current source of truth for the shell and its interaction elements.

## Glass recipe (the one material)

Both the account fab (`.account-fab`) and the bottom nav (`.bottom-nav`) use the
same glass so they read as one system:

```css
background: color-mix(in srgb, var(--canvas) 55%, transparent);
-webkit-backdrop-filter: blur(24px) saturate(1.7);
backdrop-filter: blur(24px) saturate(1.7);
border: 1px solid color-mix(in srgb, var(--ink) 12%, transparent);
box-shadow: 0 4px 16px rgba(0,0,0,0.18), inset 0 1px 0 rgba(255,255,255,0.10);
```

- `color-mix` tints the glass with the theme's card color at 55% so it works in
  light **and** dark without hardcoded rgba. The inset top highlight gives the
  "lit edge" of frosted glass. Content scrolls *under* the glass (it overlays,
  see below) so the blur has something to refract.
- Requires iOS 16.2+ (our floor is 16) — `color-mix` + `backdrop-filter` are
  both supported there.

## Shell layout — overlay + auto-hide

- **No topbar.** The header is a single 40px circular **account fab**, floating
  top-right (`position: absolute`, cleared from the notch via
  `env(safe-area-inset-top)`). Branding + phase live in the content's phase
  banner, not the chrome.
- **Both chrome pieces are `position: absolute`** over the content, not flex
  rows. The scroll region (`.content-area.with-chrome`) pads itself to clear
  them: `padding-top: calc(env(safe-area-inset-top) + 56px)` and
  `padding-bottom: calc(env(safe-area-inset-bottom) + 94px)`. **Why overlay and
  not flex:** translating a flex-reserved bar off-screen leaves a blank strip;
  absolute overlay + content padding lets the content fill the screen when the
  chrome hides.
- **Auto-hide (mobile only):** a scroll listener on `.content-area` toggles
  `.chrome-hidden` on the shell — down past 48px hides, up reveals, near-top
  always shows (6px hysteresis so it doesn't jitter). The JS early-returns at
  `window.innerWidth >= 720`; desktop keeps in-flow bars.
- **Collapse-to-circle:** when hidden, the nav doesn't just slide away — it
  shrinks to a **54px circle at the bottom-left** showing only the active tab's
  icon (`.bottom-nav.collapsed`, `margin-left: 12px; margin-right: auto`). Tap
  it to re-reveal the full chrome. Keeps one-tap navigation available while
  immersed in content.
- **Safe areas everywhere:** `env(safe-area-inset-*)` on the fab top, nav
  bottom, and content padding — verified needs on-device (the preview reports
  inset 0).

## Iridescent tap feedback (`useRipple` + `.tap-ripple`)

A rainbow "droplet" that expands from the exact touch point — the app's signature
tap affordance, shared by nav items and tappable cards.

- Hook: `src/hooks/useRipple.tsx` returns `{ ripples, spawnRipple }`. Wire
  `onPointerDown={spawnRipple}` and render `{ripples}` inside a
  `position: relative; overflow: hidden` host.
- Visual: a `conic-gradient` rainbow circle, `mix-blend-mode: screen`,
  `filter: blur(1px)`, scaling `0 → 12` and fading over **0.38s** (kept short so
  a tab change feels immediate, not like waiting out an animation).
- **Iridescent active ring** (nav active state): a masked `conic-gradient`
  border — `background: conic-gradient(...)` + `padding: 1.2px` +
  `-webkit-mask` xor/exclude — draws a 1px rainbow outline around the active
  item without a real border.
- ⚠️ Chrome runs transform/opacity animations on the **compositor**, so
  `getComputedStyle` reports the *base* value mid-animation — you can't measure
  ripple scale or a hidden-bar transform from JS; verify visually.

## Tappable drill-down cards

Summary cards on the dashboard drill into detail sheets (SL-38/39):

- `.card.tappable` = `position: relative; overflow: hidden; cursor: pointer`.
  Add `{ripples}` + `onPointerDown={spawnRipple}` for the iridescent tap, and a
  faint `›` chevron in the eyebrow to signal "more".
- ACWR → **Training Load** sheet (heatmap + weekly bars + acute/chronic).
  Readiness → **Recovery Inputs** sheet. The dashboard stays sparse (ACWR +
  Readiness stacked full-width); depth lives one tap away.

## Contribution heatmap (`ContributionHeatmap`)

GitHub-style daily-load calendar — the "how hard, how often" view.

- **Fluid, never scrolls:** a CSS grid of `repeat(weeks, 1fr)` columns × 7 rows
  with `aspect-ratio: 1` cells, so the whole ~year fits any container width
  (phone included) with no horizontal scroll. (An earlier fixed-cell version
  scrolled — the fluid grid replaced it.)
- 5 levels: empty = `--surface-2`; 1–4 = `--success` at 0.32 / 0.52 / 0.74 /
  0.96 alpha, bucketed by `ceil(value / maxDaily × 4)`. Legend Less→More.
  Weekday rows label Mon/Wed/Fri; month labels mark the column where the month
  changes (skipping collisions).

## Detail sheets & full-height variant

- Detail pages are bottom sheets (`Sheet`) — bottom-anchored on mobile, centered
  dialog ≥720px, consistent with Log/Phases/Account.
- `Sheet` accepts `fullHeight` → `.modal-sheet.full { height: 92dvh }` (86vh on
  desktop) so a sheet whose content loads async (e.g. Phases) doesn't jump its
  height as data arrives.

## Nav shape

- **Mobile:** compact floating pill (`max-width: 360px`, radius 22), column
  items (icon over label), clean line SVG icons (house / gauge / clock).
- **Desktop:** flat top bar of **rounded pill segments**
  (`border-radius: 999px`, active = tinted primary fill), row items, smaller
  icons — no auto-hide, no collapse.
