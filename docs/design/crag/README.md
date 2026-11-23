## Summary

Decision: Round 4 tones the moon look down and rebuilds it so the originals can be retired. The iridescent shimmer now appears only on the Send-o-meter fill, the primary button and the roo's edge. Everything else is calm navy and moonlight white, with one soft violet for links and selection. Titles and numbers use a sturdy slab (Zilla Slab) and body text a clean sans (Inter). The roo is a kit of fixed parts, closer to the original, with longer legs and climbing shoes. Every pose and icon is the same parts re-posed. Eight close-crop icons replace the original icon, Profile first. The crag is faceted, overhanging granite everywhere, and a new loading screen in that style replaces the original. Every app screen is drawn by Blocks with the crag pack's tokens.
Screens: Today (4 weathers), Send conditions, Session, Board, route, Flashed!, Force, Log, Logbook, Settings, App icon, loading, the three screenshot steps, board setup, wiring check, board import, old data, iCloud sync, empty, error, first run, the watch, the icon sheet, the roo kit poses, the roo model sheet and the weather sheet, at 390 and 1440 (61 images).
Open questions: (1) The roo kit is a first rig: are its proportions (long legs, long arms, round ears) right before more poses are built on it? (2) Five Blocks kinds are drawn as marked stand-ins (listed below); they still need to be filed in blocks, which this lane does not do.

## What this round decides

- **Shimmer in three places only.** The purple-teal-pink shimmer is on the Send-o-meter moon fill, the primary button (one per screen: **Start session**, **Sent**, **Next rep**, …) and the roo's die-cut edge. Charts, the force curve, chips, toggles, steps and tags use soft violet `#B9A8FF` (links and selection) or plain moonlight white. HRV and Sleep are plain moonlight moons. The friction number is plain text. The loading bar is violet.
- **Type.** Zilla Slab 600/700 for screen titles, card headers, numbers and grades: a sturdy, guidebook-like slab. Inter 400–600 for body, rows and labels. Barlow is gone.
- **The roo kit** (`pack/roo.mjs`, `pack/roo-master.svg`, `pack/rig.json`, `pack/poses.json`):
  - The parts: one body, one head (side and front drawings), two ears, two arms, two thighs, two shins, two climbing shoes and a tail. Each is drawn once at its own pivot.
  - A pose is only a list of joint angles, an optional lift and props (chalk bag, hold, bar, flash bolt, PR star, zz). The iridescent edge is the whole posed silhouette stroked twice (cutline, then shimmer), so it always wraps the pose.
  - Closer to the original: black fur, a white muzzle, white cheek spots, round ears with grey insides. Legs are long (2.4 heads) and end in white climbing shoes with a dark rand and a violet strap.
  - The kit has 15 poses: stand, bust, sit, chalk-up, crimp, hang, dyno, flash, send, fall, rest, PR, shelter, moon-watch, plus the front and back views.
- **Icons** (`pack/icons/*.svg`, 1024 px). Eight close crops of the kit, each on a dark navy background with a moon or crag hint:
  - **Profile** (side bust under the moon) is the new default and replaces the original icon.
  - **Crimp** (a paw on a hold), **Chalk-up** (the bag and a dusty paw), **Dyno** (the arm reaching out of frame), **Shoe** (a climbing shoe on a foothold), **Peek** (over a boulder lip), **Rest** (asleep under a crescent) and **Send** (a raised fist).
- **The scene.** The crag is faceted, overhanging granite like the original cave art: a big leaning overhang with pockets and cracks, a second boulder, back ridges, flagstone pads and a chalk bag, under the moon and stars.
  - The rim of each boulder catches a soft lavender moonlight line (not shimmer).
  - The weather shows inside the night: a dawn glow, rain streaks with a hazy moon, and fog bands.
  - The scene roo reacts: it watches the moon (clear), chalks up (dawn), shelters (rain) and sleeps (fog). On the phone it sits on the overhang's lip, inside Today's window; at 1440 it stands on the ground.
- **Loading** is new and replaces the original screen: the same faceted crag and moon, with the kit roo mid-dyno toward the moon on a dotted arc, the Zilla Slab wordmark and a violet progress bar.
- **Built on Blocks.** Every app screen is a Blocks `screen` drawn by Blocks' own HTML shell (`blocks/blocks.js`, vendored from blocks `staging` at the commit in `blocks/PIN`).
  - They use only Blocks kinds (`card`, `stat`, `list`/`row`, `button`, `chips`, `chart`, `steps`, `form`, `section`, `text`) plus the five stand-ins below.
  - The tab bar is Blocks' layout `nav`; at 1440 the pack turns it into a left rail.
  - The look is the pack: `pack/crag.css` sets Blocks' colour tokens and restyles its classes (glass cards, pill buttons, slab numbers).
  - `app.css` holds only one app-level rule: Today's scene window on the phone.
- **Words.** Plain **Start session** (VoiceOver reads the same). Slang only at the moments: **Flashed!**, **PR!**, "Whipper", **Project**.
- **No scrolling during a session.** Session and Force each fit on one screen on the phone (390 × 844) and on the watch.

## Images

`png/<screen>-390.png` is the phone and `png/<screen>-1440.png` is web and iPad. At 1440 the tab bar becomes the left rail, and screens with a big stand-in use two columns. Every image is the clear night unless its name says otherwise. A dashed **stand-in** tag marks each part Blocks can't draw yet.

| Image | Decision it shows |
|---|---|
| `today` | The full night scene with the roo on the overhang's lip watching the moon. The conditions card (Pine Gully · 14° · 52% · Friction 78 ›), the Send-o-meter (the moon filled with shimmer to 82, SEND; plain HRV and Sleep moons), **Start session** in shimmer, and This week. At 1440 the cards sit on the right with Last ticks added. |
| `today-dawn-390`, `today-rain-390`, `today-rain-1440`, `today-fog-1440` | The weathers inside the night: the dawn glow (the roo chalks up), rain (the roo shelters, the moon dims) and fog bands (the roo sleeps). |
| `states-390`, `states-1440` | The four weathers side by side. |
| `session-rain-390` | A dimmed screen keeps the weather blurred behind its cards. |
| `conditions` | The chip opens the sheet: friction 78 and its rank, temp, humidity, dew point, wind, the 30-day chart (Blocks `chart`, violet), the best window and the source (Open-Meteo). |
| `session` | A live session: time, tries, sends, top grade and HR. **On now**, **Sent** (shimmer) and **Fell**. The last two ticks and **End session**. It fits with no scrolling. |
| `send` | **Flashed!** with the flash roo. |
| `board`, `route` | Board home (set chips and routes) and route detail (the hold board stand-in, stats, **Light it up**). The four hold colours stay, because they mean hold roles. |
| `force` | Max hang, live: the curve in violet against your old best, peak/mean/time/bodyweight, and the **PR!** roo. It fits with no scrolling. |
| `log`, `logbook` | The month: stats and sends by grade (Blocks `chart`). Then every tick by day. |
| `settings` | Scene (**Live weather** or pin one of four), Look (App icon: Profile), Data and Account. |
| `appicon` | Settings › App icon: the eight crops, with Profile selected as the default. |
| `icons-390`, `icons-1440` | The full-size icon sheet: Profile large and at 180, 120, 87, 60, 40 and 29 px, then all eight. |
| `mascots-390`, `mascots-1440` | The roo kit's poses and where each one appears. |
| `model-390`, `model-1440` | The model sheet: front, side and back on a head-unit grid, the proportions, the 13 parts and every colour. |
| `loading` | The new loading screen. |
| `pick`, `check`, `cantread` | #1056's three screenshot steps: the crop, the hold check with one unsure hold, and "can't read it" (the shelter roo). |
| `boardsetup`, `wiring`, `boardimport` | #1047: board setup, the wiring check (the four corners lit) and the route import. |
| `dataimport`, `sync` | #1045: bringing over old data, and iCloud sync. |
| `empty`, `error`, `firstrun` | Empty Log (the resting roo), Error (the falling roo, "Gauge not found") and first run (the chalk-up roo, three permissions). |
| `watch-390`, `watch-1440` | Apple Watch: Start (the moon Send-o-meter), Session (big **Sent** and **Fell**), live Force and **Flashed!**. |

## Changes from #1046 and round 3, named

- The shimmer is gone from chips, toggles, charts, the force curve, week dots, HRV/Sleep and the friction pill. The friction score is now plain text in the conditions card.
- This week shows three numbers (sessions, sends, top) instead of seven dots.
- The original icon and the original loading screen are replaced, so their art (`ref/original-*.png`) stays as reference only.
- Screens are Blocks screens. The round-3 hand-built HTML is deleted.

## Swag pack "crag"

The pack's contents, as they would move to jirathip-dev/swag:

- **Tokens** (`pack/crag.css`, also written to `pack/tokens.json`):
  - Blocks' scheme colours: `bg` #070A1F, `card` glass rgba(17,21,48,.72) (solid #111530), `edge`, `line`, `scrim`, `fg` #EEF0FA, `mute` #B3B8D4, `l`/`link` #B9A8FF, `g` #8FD9B6, `a` #F2CB8B, `r` #FF9DB0, `p`, `c` and the `fk-*` pairs.
  - Extras: `on-iri` #120F2E, `select`, and `iri` (the shimmer: #C2A8FF → #8FE6E0 → #FFB3DC).
  - Shape and space: radius 22, buttons as pills, seam 10, controls 44, the primary button 56, glass blur 22, motion 0.
  - Type: `display` Zilla Slab and `body` Inter.
- **Fonts** (`fonts/`): Zilla Slab 600 and 700 (Mozilla, SIL OFL 1.1) and Inter, variable 400–600 (SIL OFL 1.1). The licences are `fonts/*-OFL.txt`.
- **Roo kit:**
  - `pack/roo-master.svg` (every part and prop at its pivot), `pack/rig.json` (each part's parent, attach point and draw order, side and front), `pack/poses.json` (joint angles per pose) and `pack/roo.mjs` (the renderer).
  - Colours: fur #12131F, far limb #1E2033, near arm #1D2038, seam #4A4E6E, inner ear #3C3F5C, muzzle #ECEEF8, spots #D3D7EC, shoe #E4E6F2, rubber #1A1C2C, strap #A99CF0 and cutline #07081A, plus the shimmer edge.
- **Icons:** `pack/icons/*.svg`, eight at 1024 px, made from the kit by `pack/icons.mjs`.
- **Scene:** `pack/scene.mjs`.
  - Faceted overhangs (seeded low-poly facets lit from the moon side), pockets, cracks, a lavender rim, slabs, the bag, the moon and stars.
  - Dawn, rain and fog layers.
  - The scene roo per weather.
  - A later scene pack (#1061) swaps the art and keeps these states.
- **New Blocks kinds** (stand-ins here, each to be filed in blocks):
  1. **Scene layer**: a full-screen background behind a screen, full on Today and dimmed with blur elsewhere, with a state (weather) the app sets.
  2. **Moon gauge**: a value 0–100 as a moon phase with REST/TRAIN/SEND marks and small satellite moons. The fill takes the pack's shimmer.
  3. **Hold board**: a grid with lit hold roles (start, hand, finish, foot), an "unsure" ring and a photo-crop mode.
  4. **Figure / moment**: a pack-supplied character pose with a big word and a line. Blocks' theme `figure` hook is the likely home.
  5. **Icon grid**: a picker of images with one selected.
  - The force curve uses Blocks' `plot` kind once it lands on blocks `staging`. That build has no `plot` renderer yet, so it is drawn as a stand-in too.
- **Blocks behaviour to raise with blocks:**
  - The HTML shell lowercases screen titles, so the mock puts the case back.
  - The default look adds brackets and lowercase to buttons, which the pack overrides. A pack needs to keep the case it is given.

## Contrast (WCAG AA)

Each text colour is checked on the glass card over the lightest part of each weather's scene (the blurred moon halo, the dawn glow, the fog band) and over its darkest part. Link and bad text are also checked on their tinted buttons, text on the shimmer against each of its three colours, and titles on the dimmed scene. Body text needs 4.5:1 and large text 3:1. All 48 pairs pass. `node contrast.mjs` reads `pack/crag.css` and exits non-zero on a failure.

| Weather | Text | On | Light part | Dark part | Needs | Result |
|---|---|---|---|---|---|---|
| clear | `fg` #EEF0FA | `card` | 12.41 | 16.34 | 4.5 | pass |
| clear | `mute` #B3B8D4 | `card` | 7.20 | 9.48 | 4.5 | pass |
| clear | `link` #B9A8FF | `card` | 6.79 | 8.94 | 4.5 | pass |
| clear | `g` #8FD9B6 | `card` | 8.57 | 11.29 | 4.5 | pass |
| clear | `a` #F2CB8B | `card` | 9.19 | 12.11 | 4.5 | pass |
| clear | `r` #FF9DB0 | `card` | 7.19 | 9.46 | 4.5 | pass |
| clear | `link` #B9A8FF | `button` | 5.35 | 7.26 | 4.5 | pass |
| clear | `r` #FF9DB0 | `bad-button` | 5.89 | 8.05 | 4.5 | pass |
| clear | `on-iri` #120F2E | `iri-purple` | 9.12 | 9.12 | 4.5 | pass |
| clear | `on-iri` #120F2E | `iri-teal` | 12.85 | 12.85 | 4.5 | pass |
| clear | `on-iri` #120F2E | `iri-pink` | 11.23 | 11.23 | 4.5 | pass |
| clear | `fg` #EEF0FA | `dim` | 10.82 | 18.08 | 3 | pass |
| dawn | `fg` #EEF0FA | `card` | 12.17 | 16.26 | 4.5 | pass |
| dawn | `mute` #B3B8D4 | `card` | 7.06 | 9.43 | 4.5 | pass |
| dawn | `link` #B9A8FF | `card` | 6.66 | 8.89 | 4.5 | pass |
| dawn | `g` #8FD9B6 | `card` | 8.41 | 11.23 | 4.5 | pass |
| dawn | `a` #F2CB8B | `card` | 9.02 | 12.04 | 4.5 | pass |
| dawn | `r` #FF9DB0 | `card` | 7.05 | 9.41 | 4.5 | pass |
| dawn | `link` #B9A8FF | `button` | 5.25 | 7.22 | 4.5 | pass |
| dawn | `r` #FF9DB0 | `bad-button` | 5.76 | 7.99 | 4.5 | pass |
| dawn | `on-iri` #120F2E | `iri-purple` | 9.12 | 9.12 | 4.5 | pass |
| dawn | `on-iri` #120F2E | `iri-teal` | 12.85 | 12.85 | 4.5 | pass |
| dawn | `on-iri` #120F2E | `iri-pink` | 11.23 | 11.23 | 4.5 | pass |
| dawn | `fg` #EEF0FA | `dim` | 10.24 | 17.91 | 3 | pass |
| rain | `fg` #EEF0FA | `card` | 13.99 | 16.34 | 4.5 | pass |
| rain | `mute` #B3B8D4 | `card` | 8.12 | 9.48 | 4.5 | pass |
| rain | `link` #B9A8FF | `card` | 7.65 | 8.94 | 4.5 | pass |
| rain | `g` #8FD9B6 | `card` | 9.66 | 11.29 | 4.5 | pass |
| rain | `a` #F2CB8B | `card` | 10.36 | 12.11 | 4.5 | pass |
| rain | `r` #FF9DB0 | `card` | 8.10 | 9.46 | 4.5 | pass |
| rain | `link` #B9A8FF | `button` | 6.06 | 7.26 | 4.5 | pass |
| rain | `r` #FF9DB0 | `bad-button` | 6.65 | 8.05 | 4.5 | pass |
| rain | `on-iri` #120F2E | `iri-purple` | 9.12 | 9.12 | 4.5 | pass |
| rain | `on-iri` #120F2E | `iri-teal` | 12.85 | 12.85 | 4.5 | pass |
| rain | `on-iri` #120F2E | `iri-pink` | 11.23 | 11.23 | 4.5 | pass |
| rain | `fg` #EEF0FA | `dim` | 13.81 | 18.08 | 3 | pass |
| fog | `fg` #EEF0FA | `card` | 11.64 | 16.19 | 4.5 | pass |
| fog | `mute` #B3B8D4 | `card` | 6.75 | 9.39 | 4.5 | pass |
| fog | `link` #B9A8FF | `card` | 6.36 | 8.85 | 4.5 | pass |
| fog | `g` #8FD9B6 | `card` | 8.04 | 11.19 | 4.5 | pass |
| fog | `a` #F2CB8B | `card` | 8.62 | 11.99 | 4.5 | pass |
| fog | `r` #FF9DB0 | `card` | 6.74 | 9.37 | 4.5 | pass |
| fog | `link` #B9A8FF | `button` | 5.00 | 7.17 | 4.5 | pass |
| fog | `r` #FF9DB0 | `bad-button` | 5.56 | 7.94 | 4.5 | pass |
| fog | `on-iri` #120F2E | `iri-purple` | 9.12 | 9.12 | 4.5 | pass |
| fog | `on-iri` #120F2E | `iri-teal` | 12.85 | 12.85 | 4.5 | pass |
| fog | `on-iri` #120F2E | `iri-pink` | 11.23 | 11.23 | 4.5 | pass |
| fog | `fg` #EEF0FA | `dim` | 9.44 | 17.76 | 3 | pass |

## Render

- `./render.sh` writes every image in `png/` with the headless Chromium in the host's Playwright cache (set `CHROME` to override).
- `SCREENS="today route" KEEP=1 ./render.sh` redraws only those screens.
- Open `index.html?s=<screen>&m=<weather>` to view one. The weathers are clear, dawn, rain and fog. Extra pages: `icons`, `mascots`, `model`, `states`, `watch`, `loading`.
- `node pack/build.mjs` rewrites the pack files (`roo-master.svg`, `rig.json`, `poses.json`, `tokens.json`, `icons/*.svg`) from the kit.
- Earlier rounds: round 1 (four themes) is at `4b656d29`, round 2 (Headlamp) at `6f8a9a5a`, and round 3 (iridescent moon) at `c24b31f9`.
