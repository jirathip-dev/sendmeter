## Summary

Decision: Round 5's look stands as approved, with two fixes to the roo kit. The roo has one round pink blush dot on its cheek (one per cheek when it faces front), not two white spots, in every pose, icon and the model sheet. Its climbing shoes now look like modern bouldering shoes: a downturned pointed toe, a black rubber rand and toe cap, a thick black sole, a soft-violet upper, two pale velcro straps and a violet heel tab, still flat and chunky. The Shoe icon shows the new shoe edging a foothold. Everything else, including the thin lavender rim, is unchanged.
Screens: every image is re-rendered from the fixed kit (63 images at 390 and 1440); the model sheet, roo poses and icon sheet show the fixes best.
Open questions: none. Five Blocks kinds are still marked stand-ins (listed below); filing them in blocks is not this lane's job.

## Round 6 fixes

- **One blush dot.** The kit's head part (its master drawing) now carries a single round blush dot (#E59AB8) in the side view, replacing the two white cheek spots. The front view shows one dot on each cheek. Every pose, icon and screen roo inherits it.
- **Bouldering shoes.** The shoe part is redrawn from the owner's references (no reference image was placed, so it follows the description). It has a downturned, slightly asymmetric pointed toe and a black rubber shell that forms the rand, toe cap and a thick sole. It also has a soft-violet upper panel (#A99CF0, the palette's one accent), two pale velcro straps (#ECEEF8) and a violet pull-on heel tab. The front view is a black toe cap under a violet upper with one strap.
- **Shoe icon.** It is now a close crop of the kit's own shin and shoe parts, posed with the toe edging a granite foothold under the moon, instead of a whole-body crop.
- **Kit colours.** New: blush, shoe upper, velcro strap and chalk bag (the bag keeps its old pale colour). The rubber is now near-black (#0B0C16).
- Images: `png/model-*` (the dot and the shoe in front, side and back), `png/mascots-*` (every pose), `png/icons-*` and `png/appicon-*` (the dot and the new Shoe icon).

## Round 5 changes

- **The roo is shorter and cuter.** The head is a circle (one head unit). The roo stands 3.2 heads tall with ears, down from 6.2. It has round-tipped ears, a round belly, stubby arms, a round haunch, a short shin and a big climbing shoe. The face keeps the original: a white muzzle, a black nose with a smile, a bead eye and a cheek spot (round 6: one pink blush dot).
- **Flat, Cooee style.** Every part is one flat fill with no seam lines, and depth comes from tone: the far limbs are darker and the near arm is lighter. There is no iridescent cutline. One thin flat rim (#7471B0) runs round the silhouette and the near arm, so the black roo still reads on the night sky. The icons use the same rim, scaled thin.
- **Poses re-posed for the new build.** Hang, Flash and PR face front with both arms up in a V, because short arms cannot clear the big head side-on. Crimp, Dyno and Send reach forward. Every pose stands on one ground line.
- **Moonstone buttons.** The primary button is a solid deep violet (#46379A) with a faint granite grain, a thin pearl rim and white slab text. Pressing it sweeps a soft purple-teal-pink glint across. Other buttons are unchanged.
- **Shimmer only on the Send-o-meter fill.** It is gone from the roo and the primary button (it shows only on press), including the watch's Start session and Sent.

## What this round decides (round 4, still standing)

- **Shimmer on the Send-o-meter fill only** (round 5; round 4 also had it on the primary button and the roo's edge). Charts, the force curve, chips, toggles, steps and tags use soft violet `#B9A8FF` (links and selection) or plain moonlight white. HRV and Sleep are plain moonlight moons. The friction number is plain text. The loading bar is violet.
- **Type.** Zilla Slab 600/700 for screen titles, card headers, numbers and grades: a sturdy, guidebook-like slab. Inter 400–600 for body, rows and labels. Barlow is gone.
- **The roo kit** (`pack/roo.mjs`, `pack/roo-master.svg`, `pack/rig.json`, `pack/poses.json`):
  - The parts: one body, one head (side and front drawings), two ears, two arms, two thighs, two shins, two climbing shoes (side and front drawings) and a tail. Each is drawn once at its own pivot.
  - A pose is only a list of joint angles, an optional lift and props (chalk bag, hold, bar, flash bolt, PR star, zz). The thin rim is the whole posed silhouette stroked once behind the fills.
  - The kit has 16 poses: stand, bust, sit, chalk-up, crimp, hang, dyno, flash, send, fall, rest, PR, shelter and moon-watch, plus the front and back views.
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
| `today` | The full night scene with the roo on the overhang's lip watching the moon. The conditions card (Pine Gully · 14° · 52% · Friction 78 ›), the Send-o-meter (the moon filled with shimmer to 82, SEND; plain HRV and Sleep moons), **Start session** in Moonstone, and This week. At 1440 the cards sit on the right with Last ticks added. |
| `today-dawn-390`, `today-rain-390`, `today-rain-1440`, `today-fog-1440` | The weathers inside the night: the dawn glow (the roo chalks up), rain (the roo shelters, the moon dims) and fog bands (the roo sleeps). |
| `states-390`, `states-1440` | The four weathers side by side. |
| `session-rain-390` | A dimmed screen keeps the weather blurred behind its cards. |
| `conditions` | The chip opens the sheet: friction 78 and its rank, temp, humidity, dew point, wind, the 30-day chart (Blocks `chart`, violet), the best window and the source (Open-Meteo). |
| `session` | A live session: time, tries, sends, top grade and HR. **On now**, **Sent** (Moonstone) and **Fell**. The last two ticks and **End session**. It fits with no scrolling. |
| `send` | **Flashed!** with the flash roo. |
| `board`, `route` | Board home (set chips and routes) and route detail (the hold board stand-in, stats, **Light it up**). The four hold colours stay, because they mean hold roles. |
| `force` | Max hang, live: the curve in violet against your old best, peak/mean/time/bodyweight, and the **PR!** roo. It fits with no scrolling. |
| `log`, `logbook` | The month: stats and sends by grade (Blocks `chart`). Then every tick by day. |
| `settings` | Scene (**Live weather** or pin one of four), Look (App icon: Profile), Data and Account. |
| `appicon` | Settings › App icon: the eight crops, with Profile selected as the default. |
| `icons-390`, `icons-1440` | The full-size icon sheet: Profile large and at 180, 120, 87, 60, 40 and 29 px, then all eight. |
| `buttons-390`, `buttons-1440` | Moonstone: the primary button at rest and pressed (the glint), the plain button, and the surface at 4× to show the grain and pearl rim. |
| `mascots-390`, `mascots-1440` | The roo kit's poses and where each one appears. |
| `model-390`, `model-1440` | The model sheet: front, side and back on a one-head grid, the proportions, the 13 parts and every colour. |
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
  - Extras: `select`, `iri` (the shimmer, #C2A8FF → #8FE6E0 → #FFB3DC, for the Send-o-meter fill only), and Moonstone: `moonstone` #46379A, `on-moonstone` #F6F4FF, `pearl` (the rim gradient) and `grain` (an SVG noise tile).
  - Shape and space: radius 22, buttons as pills, seam 10, controls 44, the primary button 56, glass blur 22, motion 0.
  - Type: `display` Zilla Slab and `body` Inter.
- **Fonts** (`fonts/`): Zilla Slab 600 and 700 (Mozilla, SIL OFL 1.1) and Inter, variable 400–600 (SIL OFL 1.1). The licences are `fonts/*-OFL.txt`.
- **Roo kit:**
  - `pack/roo-master.svg` (every part and prop at its pivot), `pack/rig.json` (each part's parent, attach point and draw order, side and front), `pack/poses.json` (joint angles per pose) and `pack/roo.mjs` (the renderer).
  - Colours: fur #1A1C30, far limb #111222, near arm #23263F, inner ear #4A4E78, muzzle #ECEEF8, spots #D3D7EC (chalk dust, Zz), blush #E59AB8, shoe upper #A99CF0, rubber #0B0C16, velcro strap #ECEEF8, chalk bag #E4E6F2 and the rim #7471B0. No shimmer.
- **Icons:** `pack/icons/*.svg`, eight at 1024 px, made from the kit by `pack/icons.mjs`.
- **Scene:** `pack/scene.mjs`.
  - Faceted overhangs (seeded low-poly facets lit from the moon side), pockets, cracks, a lavender rim, slabs, the bag, the moon and stars.
  - Dawn, rain and fog layers.
  - The scene roo per weather.
  - A later scene pack (#1061) swaps the art and keeps these states.
- **New Blocks kinds** (stand-ins here, each to be filed in blocks):
  1. **Scene layer**: a full-screen background behind a screen, full on Today and dimmed with blur elsewhere, with a state (weather) the app sets.
  2. **Moon gauge**: a value 0–100 as a moon phase with REST/TRAIN/SEND marks and small satellite moons. The fill takes the pack's shimmer.
  - The Moonstone button is pack CSS on Blocks' own `button`, so it needs no new kind.
  3. **Hold board**: a grid with lit hold roles (start, hand, finish, foot), an "unsure" ring and a photo-crop mode.
  4. **Figure / moment**: a pack-supplied character pose with a big word and a line. Blocks' theme `figure` hook is the likely home.
  5. **Icon grid**: a picker of images with one selected.
  - The force curve uses Blocks' `plot` kind once it lands on blocks `staging`. That build has no `plot` renderer yet, so it is drawn as a stand-in too.
- **Blocks behaviour to raise with blocks:**
  - The HTML shell lowercases screen titles, so the mock puts the case back.
  - The default look adds brackets and lowercase to buttons, which the pack overrides. A pack needs to keep the case it is given.

## Contrast (WCAG AA)

Each text colour is checked on the glass card over the lightest part of each weather's scene (the blurred moon halo, the dawn glow, the fog band) and over its darkest part. Link and bad text are also checked on their tinted buttons, and titles on the dimmed scene. White text on Moonstone is checked on its lightest stop and on the press glint at each of its three colours. Body text needs 4.5:1 and large text 3:1. All 56 pairs pass. `node contrast.mjs` reads `pack/crag.css` and exits non-zero on a failure.

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
| clear | `on-moonstone` #F6F4FF | `moonstone-top` | 7.02 | 7.02 | 4.5 | pass |
| clear | `on-moonstone` #F6F4FF | `moonstone` | 8.49 | 8.49 | 4.5 | pass |
| clear | `on-moonstone` #F6F4FF | `glint-violet` | 4.90 | 4.90 | 4.5 | pass |
| clear | `on-moonstone` #F6F4FF | `glint-teal` | 5.13 | 5.13 | 4.5 | pass |
| clear | `on-moonstone` #F6F4FF | `glint-pink` | 4.59 | 4.59 | 4.5 | pass |
| clear | `fg` #EEF0FA | `dim` | 10.82 | 18.08 | 3 | pass |
| dawn | `fg` #EEF0FA | `card` | 12.17 | 16.26 | 4.5 | pass |
| dawn | `mute` #B3B8D4 | `card` | 7.06 | 9.43 | 4.5 | pass |
| dawn | `link` #B9A8FF | `card` | 6.66 | 8.89 | 4.5 | pass |
| dawn | `g` #8FD9B6 | `card` | 8.41 | 11.23 | 4.5 | pass |
| dawn | `a` #F2CB8B | `card` | 9.02 | 12.04 | 4.5 | pass |
| dawn | `r` #FF9DB0 | `card` | 7.05 | 9.41 | 4.5 | pass |
| dawn | `link` #B9A8FF | `button` | 5.25 | 7.22 | 4.5 | pass |
| dawn | `r` #FF9DB0 | `bad-button` | 5.76 | 7.99 | 4.5 | pass |
| dawn | `on-moonstone` #F6F4FF | `moonstone-top` | 7.02 | 7.02 | 4.5 | pass |
| dawn | `on-moonstone` #F6F4FF | `moonstone` | 8.49 | 8.49 | 4.5 | pass |
| dawn | `on-moonstone` #F6F4FF | `glint-violet` | 4.90 | 4.90 | 4.5 | pass |
| dawn | `on-moonstone` #F6F4FF | `glint-teal` | 5.13 | 5.13 | 4.5 | pass |
| dawn | `on-moonstone` #F6F4FF | `glint-pink` | 4.59 | 4.59 | 4.5 | pass |
| dawn | `fg` #EEF0FA | `dim` | 10.24 | 17.91 | 3 | pass |
| rain | `fg` #EEF0FA | `card` | 13.99 | 16.34 | 4.5 | pass |
| rain | `mute` #B3B8D4 | `card` | 8.12 | 9.48 | 4.5 | pass |
| rain | `link` #B9A8FF | `card` | 7.65 | 8.94 | 4.5 | pass |
| rain | `g` #8FD9B6 | `card` | 9.66 | 11.29 | 4.5 | pass |
| rain | `a` #F2CB8B | `card` | 10.36 | 12.11 | 4.5 | pass |
| rain | `r` #FF9DB0 | `card` | 8.10 | 9.46 | 4.5 | pass |
| rain | `link` #B9A8FF | `button` | 6.06 | 7.26 | 4.5 | pass |
| rain | `r` #FF9DB0 | `bad-button` | 6.65 | 8.05 | 4.5 | pass |
| rain | `on-moonstone` #F6F4FF | `moonstone-top` | 7.02 | 7.02 | 4.5 | pass |
| rain | `on-moonstone` #F6F4FF | `moonstone` | 8.49 | 8.49 | 4.5 | pass |
| rain | `on-moonstone` #F6F4FF | `glint-violet` | 4.90 | 4.90 | 4.5 | pass |
| rain | `on-moonstone` #F6F4FF | `glint-teal` | 5.13 | 5.13 | 4.5 | pass |
| rain | `on-moonstone` #F6F4FF | `glint-pink` | 4.59 | 4.59 | 4.5 | pass |
| rain | `fg` #EEF0FA | `dim` | 13.81 | 18.08 | 3 | pass |
| fog | `fg` #EEF0FA | `card` | 11.64 | 16.19 | 4.5 | pass |
| fog | `mute` #B3B8D4 | `card` | 6.75 | 9.39 | 4.5 | pass |
| fog | `link` #B9A8FF | `card` | 6.36 | 8.85 | 4.5 | pass |
| fog | `g` #8FD9B6 | `card` | 8.04 | 11.19 | 4.5 | pass |
| fog | `a` #F2CB8B | `card` | 8.62 | 11.99 | 4.5 | pass |
| fog | `r` #FF9DB0 | `card` | 6.74 | 9.37 | 4.5 | pass |
| fog | `link` #B9A8FF | `button` | 5.00 | 7.17 | 4.5 | pass |
| fog | `r` #FF9DB0 | `bad-button` | 5.56 | 7.94 | 4.5 | pass |
| fog | `on-moonstone` #F6F4FF | `moonstone-top` | 7.02 | 7.02 | 4.5 | pass |
| fog | `on-moonstone` #F6F4FF | `moonstone` | 8.49 | 8.49 | 4.5 | pass |
| fog | `on-moonstone` #F6F4FF | `glint-violet` | 4.90 | 4.90 | 4.5 | pass |
| fog | `on-moonstone` #F6F4FF | `glint-teal` | 5.13 | 5.13 | 4.5 | pass |
| fog | `on-moonstone` #F6F4FF | `glint-pink` | 4.59 | 4.59 | 4.5 | pass |
| fog | `fg` #EEF0FA | `dim` | 9.44 | 17.76 | 3 | pass |
