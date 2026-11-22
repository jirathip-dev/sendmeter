## Summary

Decision: round 1, revised as you asked. One direction, outdoor crag culture with street style: dirtbag bouldering on granite, shot on 35mm film, with wobbly marker lettering, doodles and knit bands. It comes in three variations (golden-hour film, blue-hour film, sun-faded merch print), each drawn on Today, route detail and the loading screen, plus one app icon each. You pick one, and round 2 redraws every screen in it.
Screens: Today, route detail and loading, in three variations at 390 and 1440 (18 images), plus the app icons (2 images).
Open questions: (1) Which variation? (2) Blue hour is the only dark one. Ship the pick alone, or pair it with blue hour as its dark mode? (3) Is "Send it" OK on the Start button? VoiceOver still reads "Start session".

## The direction: film crag

- **Feel:** a crew's own merch print over a roll of 35mm film. Granite boulders, pines, a crash pad and a chalk bucket under the sun or the moon. Grain everywhere, a light leak on the photos, and sprocket-hole film borders around every picture (the hero, the board and the loading screen).
- **Mascot:** the plush kangaroo from your reference. It has tall pointed ears with cream insides, bead eyes, a pink cheek, a lighter muzzle and belly, short arms held in front, big flat feet and a thick tail. It is drawn soft and fuzzy, like crayon. On Today it crimps the boulder above its crash pad. On the loading screen it dynos for the red hold, with a motion blur and speed lines. No colours or photos of the plush are copied.
- **Lettering:** titles, section headers, the wordmark, grades and badges are in Shantell Sans, a hand-drawn marker face with wobbly bounce turned on. Faded print swaps the titles for Bowlby One, a chunky screen-print face. Body text stays in Barlow, and labels and chips in Barlow Condensed. That keeps numbers and lists plain and readable.
- **Street touches:** doodled eyes on the main button, a little sun, flower or cloud beside each title (folk flourishes), torn-paper **Flashed!** and **Sent** badges, and a knit zig-zag band as the section divider. No brand's logo, lettering, eye mark or photos are used.
- **Words:** slang only at key moments: **Send it** (start), **Flashed!**, **Sent**. Everything else stays short and plain.

## The three variations

| | Golden-hour film | Blue-hour film | Sun-faded merch print |
|---|---|---|---|
| Mode | Light | Dark | Light |
| Ground | Warm sand paper `#F1E4CB`, cards `#FBF4E6` | Faded navy `#1C2638`, cards `#26334A` | Bleached cotton `#EFE6D4`, cards `#F7F1E4` |
| Ink | Earth brown `#3A2618` | Chalk white `#F2ECDF` | Faded navy `#24324C` |
| Accent | Hand-painted red `#C9311C` (button, Flashed!) | Red `#D8391F` with a soft glow | Red `#C8361F` |
| Second colours | Pine `#2F5A3E` (Sent, good), ochre `#E8B85A`, navy grades `#2B3A55` | Moss green `#9FD08E` (Sent, good), sky `#9CC3DD`, sand-gold grades and headers `#F3C366` | Navy (Sent), red grades, pine for good, ochre `#E9B65A` |
| Sky | Ochre to sand, low sun | Dusk navy to peach, a moon | Pale denim blue, a flat sun |
| Texture | Heavy film grain, a warm orange light leak at the top right | Lighter grain, a cool blue leak with a warm edge | Halftone dots on the paper and photos, flat colour, an offset print shadow under cards and titles |
| Titles | Shantell Sans, brown | Shantell Sans, chalk white | Bowlby One, navy with a red offset shadow |

All fonts are SIL Open Font License 1.1, free to ship in the app and on the web. The files and their licences are in `fonts/`.

## Images

`png/<variation>-<screen>-<width>.png`, where the variation is `golden`, `blue` or `faded`.

| Image | Decision it shows |
|---|---|
| `*-today-390`, `*-today-1440` | Today keeps #1046's order: readiness, start, this week, last ticks. The Workout hero becomes a film frame of the crag, with the kangaroo crimping above its pad, above the session chips and the **Send it** button. Ticks wear torn-paper **Flashed!** and **Sent** badges, and grades are marker-drawn. At 1440, the film frame and the start panel sit side by side, and This week and Last ticks are two columns. |
| `*-route-390`, `*-route-1440` | Route detail keeps #1046's blocks: the lit board, Grade, Stars and Your tries, **Light it**, **Log send**, and your ticks. The board sits in a film frame with a tape label for the board and angle. Holds are hand-drawn rings in the four roles (green start, blue hand, pink finish, orange foot). At 1440, the board and the rest are two columns. |
| `*-loading-390`, `*-loading-1440` | The loading scene from today's app, set at the crag: a granite boulder, pines, the pad and the chalk bucket. The kangaroo dynos for the red hold, with motion blur and speed lines. The whole screen is one film frame, with the wordmark in marker lettering. Golden hour has a sun, blue hour has a moon (closest to today's night scene), and faded print is a halftone poster. |
| `icons-390`, `icons-1440` | One app icon per variation: the kangaroo catching two red holds on a dyno, on one solid colour (ochre, navy or red). Each is shown on a light and a dark wallpaper. Round 2 draws the full 16 (four poses in each of three sets, plus the iridescent sticker set). |

The tab bar uses the new kangaroo silhouettes for Session (sitting) and Force (hanging from a hangboard). They are single-colour icons at the same weight as Today, Board and Log (`icons/`).

## Changes from #1046, named

- Today's hero is now a film-framed crag scene with the mascot, not a plain card.
- **Send it** replaces the visible "Start session". **Flashed!** and **Sent** replace "Flash" and "Send". "Go" stays plain.
- At 1440, Today's This week and Last ticks are two columns, and the route is two columns.
- Section dividers are a knit band.

## Pack and Blocks (first look, final list in round 2)

- **The swag pack ("crag")** holds the chosen variation's colour tokens, the four fonts and their licences, the textures (film grain, light leak or halftone, granite speckle, knit band), the film-frame border, the torn-paper badge shape, and the doodles (sun, flower, cloud, eyes).
- **Possible new Blocks kinds,** to file in blocks once a variation is picked: a texture layer over a screen, a film-frame container with sprocket holes, a badge shape (torn paper), a separate title, header and grade font token, and a doodle slot beside a title and inside a button.

## Contrast (WCAG AA)

Every text colour is checked on its surface. It is checked plain, and again on the worst case texture: the surface mixed with mid grey at the grain's full opacity, plus the light-leak tint on the page background. Normal text needs 4.5:1. Large text (titles, headers, grades, button labels, big numbers) needs 3:1. Every pair passes. Run `node contrast.mjs` to check again. It exits non-zero on a failure.

### golden

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #3A2618 | `bg` #F1E4CB | 11.36 | 6.78 | 4.5 | pass |
| `mute` #4F3829 | `bg` #F1E4CB | 8.65 | 5.16 | 4.5 | pass |
| `title-ink` #3A2618 | `bg` #F1E4CB | 11.36 | 6.78 | 3 | pass |
| `hdr-ink` #962312 | `bg` #F1E4CB | 6.56 | 3.91 | 3 | pass |
| `ink` #3A2618 | `card` #FBF4E6 | 13.05 | 9.20 | 4.5 | pass |
| `mute` #4F3829 | `card` #FBF4E6 | 9.94 | 7.01 | 4.5 | pass |
| `good` #2F5A3E | `card` #FBF4E6 | 7.23 | 5.10 | 3 | pass |
| `grade-ink` #2B3A55 | `card` #FBF4E6 | 10.43 | 7.36 | 3 | pass |
| `on-lead` #FFF6E8 | `lead` #C9311C | 4.98 | 4.98 | 3 | pass |
| `plain-ink` #3A2618 | `card` #FBF4E6 | 13.05 | 9.20 | 3 | pass |
| `on-flash` #FFF6E8 | `flash` #C9311C | 4.98 | 4.98 | 4.5 | pass |
| `on-send` #F4EEE2 | `send` #2F5A3E | 6.85 | 5.49 | 4.5 | pass |
| `chip-on-ink` #F4EEE2 | `chip-on` #2F5A3E | 6.85 | 5.49 | 4.5 | pass |
| `ink` #3A2618 | `side` #EADBBD | 10.45 | 7.75 | 4.5 | pass |
| `mute` #4F3829 | `side` #EADBBD | 7.96 | 5.90 | 4.5 | pass |
| `side-on-ink` #F4EEE2 | `side-on` #3A2618 | 12.36 | 8.25 | 4.5 | pass |
| `brand-ink` #962312 | `side` #EADBBD | 6.04 | 4.48 | 3 | pass |
| `tab-ink` #4F3829 | `bar` #FBF4E6 | 9.94 | 7.01 | 4.5 | pass |
| `tab-on-ink` #962312 | `bar` #FBF4E6 | 7.54 | 5.31 | 4.5 | pass |

### blue

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #F2ECDF | `bg` #1C2638 | 12.89 | 6.75 | 4.5 | pass |
| `mute` #CAD3DF | `bg` #1C2638 | 10.04 | 5.26 | 4.5 | pass |
| `title-ink` #F2ECDF | `bg` #1C2638 | 12.89 | 6.75 | 3 | pass |
| `hdr-ink` #F3C366 | `bg` #1C2638 | 9.26 | 4.85 | 3 | pass |
| `ink` #F2ECDF | `card` #26334A | 10.78 | 8.33 | 4.5 | pass |
| `mute` #CAD3DF | `card` #26334A | 8.40 | 6.49 | 4.5 | pass |
| `good` #9FD08E | `card` #26334A | 7.18 | 5.55 | 3 | pass |
| `grade-ink` #F3C366 | `card` #26334A | 7.74 | 5.98 | 3 | pass |
| `on-lead` #FFF6EA | `lead` #D8391F | 4.34 | 4.48 | 3 | pass |
| `plain-ink` #F2ECDF | `card` #26334A | 10.78 | 8.33 | 3 | pass |
| `on-flash` #FFF6EA | `flash` #B92E19 | 5.66 | 5.56 | 4.5 | pass |
| `on-send` #13201A | `send` #9FD08E | 9.52 | 8.06 | 4.5 | pass |
| `chip-on-ink` #1C2638 | `chip-on` #F2ECDF | 12.89 | 10.28 | 4.5 | pass |
| `ink` #F2ECDF | `side` #172031 | 13.86 | 10.47 | 4.5 | pass |
| `mute` #CAD3DF | `side` #172031 | 10.79 | 8.15 | 4.5 | pass |
| `side-on-ink` #1C2638 | `side-on` #F2ECDF | 12.89 | 10.28 | 4.5 | pass |
| `brand-ink` #F3C366 | `side` #172031 | 9.95 | 7.52 | 3 | pass |
| `tab-ink` #CAD3DF | `bar` #26334A | 8.40 | 6.49 | 4.5 | pass |
| `tab-on-ink` #F3C366 | `bar` #26334A | 7.74 | 5.98 | 4.5 | pass |

### faded

| Text | On | Plain | On texture | Needs | Result |
|---|---|---|---|---|---|
| `ink` #24324C | `bg` #EFE6D4 | 10.36 | 7.23 | 4.5 | pass |
| `mute` #3E4859 | `bg` #EFE6D4 | 7.44 | 5.20 | 4.5 | pass |
| `title-ink` #24324C | `bg` #EFE6D4 | 10.36 | 7.23 | 3 | pass |
| `hdr-ink` #B82F1A | `bg` #EFE6D4 | 4.90 | 3.42 | 3 | pass |
| `ink` #24324C | `card` #F7F1E4 | 11.41 | 9.04 | 4.5 | pass |
| `mute` #3E4859 | `card` #F7F1E4 | 8.20 | 6.50 | 4.5 | pass |
| `good` #2F5A3E | `card` #F7F1E4 | 7.03 | 5.57 | 3 | pass |
| `grade-ink` #B82F1A | `card` #F7F1E4 | 5.39 | 4.27 | 3 | pass |
| `on-lead` #F7F1E4 | `lead` #C8361F | 4.66 | 4.71 | 3 | pass |
| `plain-ink` #24324C | `card` #F7F1E4 | 11.41 | 9.04 | 3 | pass |
| `on-flash` #F7F1E4 | `flash` #B82F1A | 5.39 | 5.25 | 4.5 | pass |
| `on-send` #F7F1E4 | `send` #24324C | 11.41 | 8.85 | 4.5 | pass |
| `chip-on-ink` #F7F1E4 | `chip-on` #24324C | 11.41 | 8.85 | 4.5 | pass |
| `ink` #24324C | `side` #E6DAC2 | 9.28 | 7.59 | 4.5 | pass |
| `mute` #3E4859 | `side` #E6DAC2 | 6.67 | 5.45 | 4.5 | pass |
| `side-on-ink` #F7F1E4 | `side-on` #24324C | 11.41 | 8.85 | 4.5 | pass |
| `brand-ink` #24324C | `side` #E6DAC2 | 9.28 | 7.59 | 3 | pass |
| `tab-ink` #3E4859 | `bar` #F7F1E4 | 8.20 | 6.50 | 4.5 | pass |
| `tab-on-ink` #962514 | `bar` #F7F1E4 | 7.26 | 5.75 | 4.5 | pass |
