## Summary

Decision: four whole-app themes, all built on today's loading-screen crag (granite, moon, pine, crash pad and chalk bucket), polished and drawn in five clock and weather states. A small roo lives in the scene and reacts to the weather. Each theme draws Today (full-screen scene, Send Conditions chip, Send-o-meter), one other screen and its app icon. You pick one, and round 2 redraws every screen in it.
Screens: Night Topo (Today, Log), Chalk & Granite (Today, Session), Field Journal (Today, Force), Headlamp Session (Today, Board route), each at 390 and 1440, plus the scene states and the four app icons (20 images).
Open questions: (1) Which theme? (2) Should a second theme ship as the dark or light alternative (for example, Field Journal by day and Night Topo by night)? (3) Does "Send it" stay on the start button? VoiceOver still reads "Start session".

## What all four share

- **The scene.** Today's loading crag, redrawn clean and illustrated (never photo-real): a faceted granite boulder with a crack and chalked pockets, a smaller boulder, a broad tree, ridges, ground slabs, grass tufts, the salmon-and-navy crash pad and the red chalk bucket. It has five states, driven by the clock and Open-Meteo: dawn, golden hour, night with moon and stars, rain, and fog. Weather comes from the phone's approximate location, or from the crag a session is logged at.
- **The roo in the scene.** It uses the plush's shape: tall pointed ears with cream insides, bead eyes, a pink cheek, a lighter muzzle and belly, short arms, big flat feet and a thick tail. It chalks up at dawn, rests under the tree at golden hour, watches the moon at night, shelters under the overhang in rain (ears back, arms hugged), and sits it out in fog. Each theme draws it in its own hand (see below).
- **Where the scene shows.** Today shows it full-screen. Session, Board, Force and Log show the same scene blurred and dimmed behind their cards, so the whole app shares the weather.
- **Send Conditions** is a glass chip at the top of Today with the crag name, temperature, humidity and the friction score (0–100). Tapping it opens the 30-day detail sheet (round 2).
- **The Send-o-meter.** One big needle gauge for Ready, from REST through TRAIN to SEND, with HRV and Sleep as two small dials beside it. No rings.
- **Words.** Slang only at key moments: **Send it** (start), **Flashed!**, **PR!**. Every other label is short and plain.
- **Fonts.** Barlow (body), Barlow Condensed (numbers and display) and Shantell Sans (Field Journal's handwritten notes only). All are SIL Open Font License 1.1, and the files and licences are in `fonts/`.
- **Tab bar.** Today, Session (sitting roo), Board, Force (hanging roo) and Log. The two roo tabs are simple silhouettes at the same weight as the others (`icons/`).

## The four themes

| | Night Topo | Chalk & Granite | Field Journal | Headlamp Session |
|---|---|---|---|---|
| Scene shown | Night, moon | Golden hour | Rain | Night, lit by a headlamp beam |
| Cards | Frosted granite glass, faint speckle | Smooth granite slabs, chalk dust, a slab shadow | Notebook pages: graph-paper grid and a red margin line | Dark glass with a warm amber edge glow |
| Text | Moonlight white `#F3F5F7` | Chalk white `#F7F4EE` | Ink navy `#1D2B47` | Warm white `#F5EDDF` |
| Accent | Headlamp amber `#F2B65A` | Chalk-bucket red `#B83A27` | Pine `#2D5A3D` | Amber glow `#FFB547` |
| Type | Clean sans, condensed uppercase headers | Condensed chalk-white numbers | Plain sans, handwritten notes on PRs | Condensed, glowing numbers |
| Send-o-meter | Thin arc, contour-line rings and fine ticks | Thick chalk-stroke arc with chalk ticks | Ink arc on graph paper, a pine SEND wedge, a note ("best in 3 weeks") | **The moon is the gauge:** it fills from crescent (REST) to full (SEND) |
| Charts | Guidebook topos: progress is a dashed route line up a boulder, with sessions as ticks on it | Tally strokes for sends | Ink lines on graph paper with handwritten callouts | Glowing dots and holds lit in the beam |
| Roo's hand | Topo ink: moonlight contour line | Chalk outline | Journal sketch: ink line over a light wash | Headlamp-lit: amber rim light |

## Images

`png/<theme>-<screen>-<width>.png`

| Image | Decision it shows |
|---|---|
| `topo-today-390`, `topo-today-1440` | Night Topo Today: the night crag full-screen, the roo by the tree watching the moon, the chip at the top, the Send-o-meter on frosted granite glass, **Send it**, and This week as a topo route line with ticks for session days. At 1440, a glass sidebar, the chip and gauge on the left, and start, week and last ticks on the right, with the scene open in the middle. |
| `topo-log-390`, `topo-log-1440` | Night Topo's other screen, Log: "Top grade · 8 weeks" drawn as a topo. The route line climbs the boulder from V3 to V5, with a tick for each session, and the roo cheers at the top. Below are totals and sessions. At 1440, sends by grade are added. |
| `chalk-today-390`, `chalk-today-1440` | Chalk & Granite Today: the golden-hour crag, the roo resting under the tree, slab cards, a chalk-stroke gauge, a red **Send it**, and This week as 12 in chalk tally strokes. |
| `chalk-session-390`, `chalk-session-1440` | Chalk & Granite's other screen, a live Session: a **Flashed!** moment with the chalk-drawn roo, the current problem with **Log send** and **Fell**, and sends today as tallies by grade. At 1440, the problems list is added. |
| `journal-today-390`, `journal-today-1440` | Field Journal Today: the rain scene, with the roo sheltering under the overhang. Notebook-page cards, an ink gauge with a handwritten note, a pine **Send it**, and This week as ink bars. |
| `journal-force-390`, `journal-force-1440` | Field Journal's other screen, Force: a max-hang curve on graph paper with a handwritten "new PR! 52.4 kg" callout and the old-best line, a **PR!** moment with the sketched roo hanging from the bar, and peak, avg and RFD. At 1440, the 8-week peak trend and recent hangs are added. |
| `headlamp-today-390`, `headlamp-today-1440` | Headlamp Session Today: the night crag dimmed, with a warm beam over the cards. The moon gauge reads 82 as a near-full moon, and the phases below mark REST, TRAIN and SEND. Session days glow in This week. |
| `headlamp-route-390`, `headlamp-route-1440` | Headlamp Session's other screen, a Board route: the lit board in the four hold roles (green start, blue hand, pink finish, orange foot), with each hold glowing, plus **Light it** and **Log send**. At 1440, it adds the grade, stars and your tries, the role legend, and last ticks. |
| `scenes-390`, `scenes-1440` | The shared scene in all five states, with the roo's reaction in each. A later scene pack (#1061) swaps the art and keeps these states. |
| `icons-390`, `icons-1440` | One app icon per theme, in cooee's flat style: a front-facing geometric roo bust with a close crop, the moon, one solid background, four flat colours, and no outline or texture. Night Topo's is today's logo polished (night navy, moon, the roo) and is the default. Each icon is shown on a light and a dark wallpaper. |

## Changes from #1046, named

- Today's background is the live crag scene instead of a plain canvas, and the cards are glass, slab, page or lit glass by theme.
- Readiness is the Send-o-meter instead of rings, and Send Conditions moves to the chip at the top.
- **Send it** replaces the visible "Start session". **Flashed!** and **PR!** are shown as moments.
- At 1440, Today's cards float around the open scene instead of filling a grid.

## Swag pack "crag" (first look; the final list comes with round 2)

- **Tokens:** each theme's text, secondary, accent, on-accent and accent-text colours, glass tint and opacity, radius, and texture opacity (`themes.css`). The scene palettes for the five states (`scene.js`).
- **Fonts:** Barlow, Barlow Condensed and Shantell Sans, with their OFL licences.
- **Textures and shapes:** granite speckle, chalk dust, graph-paper grid with margin line, headlamp beam; the scene art per state; the roo poses (sit, chalk, shelter, look, cheer, hang, fall) in each theme's hand; the app icons.
- **Possible new Blocks kinds** (to file in blocks once a theme is picked): a scene background layer with a dimmed and blurred mode; a glass card material with a texture slot; a needle gauge (and the moon-phase gauge for Headlamp); small dials; a tally mark; a topo route chart; and a chart annotation in the note font.

## Contrast (WCAG AA)

Card colours are checked at their worst case. That is the glass tint over the lightest thing in its scene (the moon, or the golden sky) and over the darkest night, with the card texture added. Screen titles are checked on the dimmed scene. Normal text needs 4.5:1, and large text 3:1. All 20 pairs pass. Run `node contrast.mjs` to check again; it exits non-zero on a failure.

| Theme | Text | On | Plain | Worst | Needs | Result |
|---|---|---|---|---|---|---|
| topo | `ink` #F3F5F7 | `card` #3c4147 | 9.42 | 7.56 | 4.5 | pass |
| topo | `mute` #CDD5DD | `card` #3c4147 | 6.94 | 5.57 | 4.5 | pass |
| topo | `accent-ink` #F9D392 | `card` #3c4147 | 7.24 | 5.81 | 4.5 | pass |
| topo | `on-accent` #1B1407 | `accent` #F2B65A | 10.10 | 10.10 | 4.5 | pass |
| topo | `title` #FFFFFF | `dim` #949289 | 3.12 | 3.12 | 3 | pass |
| chalk | `ink` #F7F4EE | `card` #4e4c4a | 7.79 | 7.79 | 4.5 | pass |
| chalk | `mute` #D3CEC5 | `card` #4e4c4a | 5.46 | 5.46 | 4.5 | pass |
| chalk | `accent-ink` #F8B3A3 | `card` #4e4c4a | 4.87 | 4.87 | 4.5 | pass |
| chalk | `on-accent` #FFF8F0 | `accent` #B83A27 | 5.43 | 5.43 | 4.5 | pass |
| chalk | `title` #FFFFFF | `dim` #97825f | 3.70 | 3.70 | 3 | pass |
| journal | `ink` #1D2B47 | `card` #ebe6d9 | 11.32 | 9.97 | 4.5 | pass |
| journal | `mute` #46536B | `card` #ebe6d9 | 6.22 | 5.47 | 4.5 | pass |
| journal | `accent-ink` #2D5A3D | `card` #ebe6d9 | 6.38 | 5.62 | 4.5 | pass |
| journal | `on-accent` #F7F1E3 | `accent` #2D5A3D | 7.06 | 6.89 | 4.5 | pass |
| journal | `title` #FFFFFF | `dim` #7b838b | 3.85 | 3.85 | 3 | pass |
| headlamp | `ink` #F5EDDF | `card` #393d44 | 9.38 | 9.38 | 4.5 | pass |
| headlamp | `mute` #D2C8B8 | `card` #393d44 | 6.59 | 6.59 | 4.5 | pass |
| headlamp | `accent-ink` #FFC46B | `card` #393d44 | 6.94 | 6.94 | 4.5 | pass |
| headlamp | `on-accent` #1C1306 | `accent` #FFB547 | 10.44 | 10.44 | 4.5 | pass |
| headlamp | `title` #FFFFFF | `dim` #6b6a63 | 5.43 | 5.43 | 3 | pass |

## Files

`index.html?t=<theme>&s=<screen>` draws any screen (`s=scenes` and `s=icons` draw the two sheets). `scene.js` is the scene and the roo, `app.js` the screens, `themes.css` the four themes. `render.sh` writes every PNG with headless Chromium. `ref/kangaroo-painting.jpeg` is the owner's painting, which sets the roo's shape and colouring.

Earlier round-1 drafts (three street-style directions, then the film-crag variations) are in this branch's history and are superseded by the amendments above.
