## Summary

Decision: round 1 of the street-style look. Three directions (chalk and tape, sticker zine, night graffiti) are drawn on Today and the route screen at phone and wide sizes, on #1046's layouts. You pick one, and round 2 redraws every screen in it.
Screens: Today and route detail, each in three directions, at 390 and 1440 (12 images).
Open questions: (1) Which direction? (2) Should the chosen look be one fixed mode (chalk and graffiti are dark, zine is light), or does it also need the other mode? (3) Is "Send it" OK as the visible label on the Start button? VoiceOver still reads "Start session".

## The three directions

| | (a) Chalk and tape | (b) Sticker zine | (c) Night graffiti |
|---|---|---|---|
| Palette | Slate `#262B2F`, chalk white `#F2F0E8`, masking tape `#EDE6D3`, tape yellow `#F3D04E`, chalk green `#A6E39A` (flash and good), chalk yellow `#F6E27A` (grades) | Cream paper `#FFF1D6`, ink `#161616`, tomato `#FF5A2E`, sun `#FFD23F`, mint `#2EC4A6`, cobalt `#2F55F0` (grades), sky `#A9C8FF` | Wall `#131217`, neon green `#3BFF8F`, pink `#FF4FB0`, cyan `#4FD0FF`, yellow `#FFE83B` (flash and grades) |
| Type | Barlow Condensed (titles, labels, buttons), Barlow (text), Caveat Brush (hand-written grades and the wordmark) | Bowlby One (titles, buttons, grades), Rubik (text) | Sedgwick Ave Display (spray-tag titles and wordmark), Bungee (numbers, grades, headers), Space Grotesk (text) |
| Textures | Chalk dust (fine noise) on every surface, faint smudges, hand-drawn card edges | Halftone dots on paper and the hero, thick ink outlines, hard offset shadows | Brick wall with spray haze (pink, cyan, green), neon glow on holds, drips under the main button |
| Shapes | Torn tape strips: section headers, badges, the main button, the selected chip and tab | Pill stickers, a star-burst for Flashed!, round die-cut stickers stuck on cards | Stencil labels, rounded neon tiles |
| Mascot | Drawn in chalk: white, rough-edged | A die-cut sticker: ink with a white cut line and a drop shadow, and stuck on the board too | Sprayed in neon green with a glow |

All fonts are SIL Open Font License 1.1, free to ship in the app and on the web. The files and their licences are in `fonts/`.

## Images

`png/<direction>-<screen>-<width>.png`, where direction is `chalk`, `zine` or `graffiti`.

| Image | Decision it shows |
|---|---|
| `*-today-390`, `*-today-1440` | Today keeps #1046's order: readiness, start, this week, last ticks. One change for every direction: the Workout mascot now stands in a hero card beside the session chips and the Start button, which reads **Send it**. Ticks wear the direction's **Flashed!** and **Sent** badges, and grades are drawn in the direction's grade face. At 1440, This week and Last ticks sit side by side. |
| `*-route-390`, `*-route-1440` | Route detail keeps #1046's blocks: the lit board, Grade, Stars and Your tries, **Light it**, **Log send** and your ticks. The board's hold colours follow the direction (chalk rings, flat outlined rings, neon glow) but keep the four roles: green start, blue hand, pink finish, orange foot. At 1440 the board and the rest sit side by side, so the whole route fits without scrolling. |

## Changes from #1046, named

- Today gets a mascot hero card. In the zine direction, a sticker also sits on the hero card and on the board.
- **Send it** replaces the visible "Start session". **Flashed!** and **Sent** replace "Flash" and "Send". "Go" stays plain. Slang is used only at these moments.
- At 1440, Today's This week and Last ticks are two columns, and the route is two columns.

## Pack and Blocks (first look, final list in round 2)

- **The swag pack ("crag")** holds the chosen direction's colour tokens, the three fonts and their licences, the texture (noise, halftone or bricks), and the shapes (tape edge, star-burst or drips).
- **Possible new Blocks kinds,** to file in blocks once a direction is picked: a texture layer on screens and tiles, a badge shape (tape, star-burst or stencil), a separate title or grade font token, and a decoration slot on a button (the drips).

## Contrast (WCAG AA)

Every text colour is checked on its surface, both plain and with the texture at its strongest. "On texture" mixes the direction's texture colour at its highest opacity over the surface. Normal text needs 4.5:1. Large text (titles, grades, button labels, big numbers) needs 3:1. Every pair passes.

### chalk

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #F2F0E8 | `bg` #262B2F | 12.53 | 9.16 | 4.5 | pass |
| `mute` #BCC3C0 | `bg` #262B2F | 7.97 | 5.83 | 4.5 | pass |
| `title-ink` #F2F0E8 | `bg` #262B2F | 12.53 | 9.16 | 3 | pass |
| `hdr-ink` #23262A | `tape` #EDE6D3 | 12.20 | 12.20 | 4.5 | pass |
| `ink` #F2F0E8 | `card` #30363B | 10.72 | 7.85 | 4.5 | pass |
| `mute` #BCC3C0 | `card` #30363B | 6.82 | 4.99 | 4.5 | pass |
| `good` #A6E39A | `card` #30363B | 8.20 | 6.00 | 3 | pass |
| `grade-ink` #F6E27A | `card` #30363B | 9.37 | 6.86 | 3 | pass |
| `on-lead` #1F2226 | `lead` #F3D04E | 10.60 | 10.60 | 3 | pass |
| `plain-ink` #F2F0E8 | `bg` #262B2F | 12.53 | 9.16 | 3 | pass |
| `on-flash` #1E2522 | `flash` #A6E39A | 10.48 | 10.48 | 4.5 | pass |
| `on-send` #23262A | `send` #EDE6D3 | 12.20 | 12.20 | 4.5 | pass |
| `on-go` #E4E2DA | `go` #3A4147 | 7.99 | 7.99 | 4.5 | pass |
| `chip-ink` #F2F0E8 | `hero` #30363B | 10.72 | 7.85 | 4.5 | pass |
| `chip-on-ink` #23262A | `chip-on` #EDE6D3 | 12.20 | 12.20 | 4.5 | pass |
| `board-tag-ink` #23262A | `board-tag` #EDE6D3 | 12.20 | 12.20 | 4.5 | pass |
| `mute` #BCC3C0 | `side` #1F2327 | 8.81 | 6.49 | 4.5 | pass |
| `side-on-ink` #23262A | `side-on` #EDE6D3 | 12.20 | 12.20 | 4.5 | pass |
| `brand-ink` #F2F0E8 | `side` #1F2327 | 13.86 | 10.20 | 3 | pass |
| `mute` #BCC3C0 | `bar` #30363B | 6.82 | 4.99 | 4.5 | pass |
| `tab-on-ink` #F6E27A | `bar` #30363B | 9.37 | 6.86 | 4.5 | pass |

### zine

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #161616 | `bg` #FFF1D6 | 16.20 | 13.23 | 4.5 | pass |
| `mute` #4D4339 | `bg` #FFF1D6 | 8.64 | 7.05 | 4.5 | pass |
| `title-ink` #161616 | `bg` #FFF1D6 | 16.20 | 13.23 | 3 | pass |
| `hdr-ink` #FFF1D6 | `hdr-bg` #161616 | 16.20 | 16.20 | 4.5 | pass |
| `ink` #161616 | `card` #FFFFFF | 18.10 | 18.10 | 4.5 | pass |
| `mute` #4D4339 | `card` #FFFFFF | 9.64 | 9.64 | 4.5 | pass |
| `good` #0B7A63 | `card` #FFFFFF | 5.28 | 5.28 | 3 | pass |
| `grade-ink` #2F55F0 | `card` #FFFFFF | 5.71 | 5.71 | 3 | pass |
| `on-lead` #161616 | `lead` #FF5A2E | 5.82 | 5.82 | 3 | pass |
| `plain-ink` #161616 | `plain` #FFD23F | 12.53 | 12.53 | 3 | pass |
| `on-flash` #161616 | `flash` #FFD23F | 12.53 | 12.53 | 4.5 | pass |
| `on-send` #161616 | `send` #2EC4A6 | 8.24 | 8.24 | 4.5 | pass |
| `on-go` #161616 | `go` #E6DCF7 | 13.74 | 13.74 | 4.5 | pass |
| `chip-ink` #161616 | `chip` #FFFFFF | 18.10 | 18.10 | 4.5 | pass |
| `chip-on-ink` #FFF1D6 | `chip-on` #161616 | 16.20 | 16.20 | 4.5 | pass |
| `board-tag-ink` #161616 | `board-tag` #FFD23F | 12.53 | 12.53 | 4.5 | pass |
| `mute` #4D4339 | `side` #FFE7B8 | 7.98 | 7.98 | 4.5 | pass |
| `side-on-ink` #FFF1D6 | `side-on` #161616 | 16.20 | 16.20 | 4.5 | pass |
| `brand-ink` #161616 | `side` #FFE7B8 | 14.97 | 14.97 | 3 | pass |
| `mute` #4D4339 | `bar` #FFFFFF | 9.64 | 9.64 | 4.5 | pass |
| `tab-on-ink` #161616 | `bar` #FFFFFF | 18.10 | 18.10 | 4.5 | pass |

### graffiti

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #F5F2FA | `bg` #131217 | 16.83 | 12.90 | 4.5 | pass |
| `mute` #BDB6CC | `bg` #131217 | 9.52 | 7.29 | 4.5 | pass |
| `title-ink` #FF4FB0 | `bg` #131217 | 6.21 | 4.76 | 3 | pass |
| `hdr-ink` #4FD0FF | `bg` #131217 | 10.47 | 8.02 | 4.5 | pass |
| `ink` #F5F2FA | `card` #1E1C25 | 15.20 | 15.20 | 4.5 | pass |
| `mute` #BDB6CC | `card` #1E1C25 | 8.60 | 8.60 | 4.5 | pass |
| `good` #3BFF8F | `card` #1E1C25 | 12.73 | 12.73 | 3 | pass |
| `grade-ink` #FFE83B | `card` #1E1C25 | 13.51 | 13.51 | 3 | pass |
| `on-lead` #0B0A0E | `lead` #3BFF8F | 14.93 | 14.93 | 3 | pass |
| `plain-ink` #4FD0FF | `bg` #131217 | 10.47 | 8.02 | 3 | pass |
| `on-flash` #0B0A0E | `flash` #FFE83B | 15.84 | 15.84 | 4.5 | pass |
| `on-send` #0B0A0E | `send` #4FD0FF | 11.09 | 11.09 | 4.5 | pass |
| `on-go` #E2DCEE | `go` #34303F | 9.57 | 9.57 | 4.5 | pass |
| `chip-ink` #F5F2FA | `chip` #26232E | 13.92 | 13.92 | 4.5 | pass |
| `chip-on-ink` #0B0A0E | `chip-on` #FF4FB0 | 6.58 | 6.58 | 4.5 | pass |
| `board-tag-ink` #0B0A0E | `board-tag` #FF4FB0 | 6.58 | 6.58 | 4.5 | pass |
| `mute` #BDB6CC | `side` #0E0D12 | 9.89 | 7.67 | 4.5 | pass |
| `side-on-ink` #3BFF8F | `side-on` #2A2733 | 11.06 | 11.06 | 4.5 | pass |
| `brand-ink` #FF4FB0 | `side` #0E0D12 | 6.45 | 5.00 | 3 | pass |
| `mute` #BDB6CC | `bar` #1E1C25 | 8.60 | 8.60 | 4.5 | pass |
| `tab-on-ink` #3BFF8F | `bar` #1E1C25 | 12.73 | 12.73 | 4.5 | pass |

## Render

`./render.sh` renders all 12 images with the headless Chromium build in the Playwright cache (set `CHROME` to use another). `node contrast.mjs` reads the tokens in each direction's stylesheet and prints the table above. It exits 1 on any failing pair. The pages are `today.html?d=<direction>` and `route.html?d=<direction>`, on `base.css` and one stylesheet per direction.
