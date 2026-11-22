## Summary

Decision: five tabs (Today, Session, Board, Force, Log), each with one obvious action. Today starts a session in one tap, a try is one tap (Fell or Sent) on phone and watch, and the new Board tab finds a route, lights it and ticks it. Everything is drawn with Blocks in Sendmeter's own chalk-and-slate palette. The bouldering touches are grades, tally marks, flash and send ticks, and a grade pyramid.
Screens: Today, Session (phone + watch), Board list, route detail with the lit board, send log, Force, Log (sessions, logbook), Settings with iCloud sync off by default, and the unchanged loading screen.
Open questions: (1) The Blocks package needs iOS 26 and the app supports iOS 17: is raising the minimum OK? (2) Lighting Kilter, Tension and Moon boards means using their Bluetooth protocols and route lists: which boards first, and is their route data ours to show? (3) Crew is limited to "with Mai, Tob" on a session, with no social feed: enough?

## Screens

Each screen has `png/<name>-390.png` (phone) and `png/<name>-1440.png` (wide: the tab bar becomes a sidebar).

| Image | Decision it shows |
|---|---|
| `today` | Readiness (Ready, HRV, Sleep) first, then the session kind and one **Start session** button. This week's ACWR, sends and peak below, then the last ticks with Flash/Send badges. Settings sits behind the top-right menu, not in a tab. |
| `session` | Live recording on the phone: the Workout mascot and elapsed time, the current route with its tries as tally marks, two large **Fell** / **Sent** buttons, a rest bar, and HR/tries/sends tiles. A first-try Sent logs a flash. At 1440 the watch stands beside it, showing the same loop. |
| `watch` | The watch's three states: climbing (Fell / Sent), resting (countdown, **Climb**) and the flash or send confirmation. Dark only, the same palette as the phone. |
| `board` | The new Board tab: board chips (Kilter, Tension, MoonBoard; spray wall comes later), search, multi-select grade chips, and a route list with your Flash/Send/Project badge and the grade. At 1440 the list and the route detail sit side by side. |
| `route` | Route detail: the board with the route's holds lit (green start, blue hand, magenta finish, orange foot), grade, stars and your tries. **Light it** is the one primary action, **Log send** opens the sheet, and your past ticks are listed below. |
| `send` | The send log as a sheet over the route: result (Flash / Send / Repeat / Go), tries, grade feel (Soft / Solid / Sandbag), stars and a beta note, then **Tick it**. Every field is preset, so a flash is two taps. |
| `force` | Live Force: the Force mascot and the Progressor link, mode chips, a large live kg figure with a L/R hand switch, the curve with its target band and peak line, peak/bodyweight/best tiles, and one **Pull** button. |
| `history` | The Log tab, Sessions view: weekly load bars, then sessions by week with their training-zone badge, duration and partners ("with Mai, Tob"). |
| `logbook` | The Log tab, Logbook view: ticks, flashes, top grade, the grade pyramid (flashes stacked on sends) and the tick list. |
| `settings` | Local-only by default. **iCloud sync** is a single opt-in toggle, off, and there is no account and no sign-in. Then grades (V-scale / Font), units, Apple Health, and gear (Tindeq, Watch, the three boards). Export, and an Erase that asks for confirmation. |
| `loading` | The splash, unchanged: the same cave art, kangaroo and overlay, shown at its rest pose. The motion stays the product's `SplashView` as it is. |

## What is kept, what is Blocks

- **Mascots:** the Workout and Force tab icons and large mascots are drawn from the product's own asset files (`Resources/Assets.xcassets`), unedited.
- **Loading:** the splash composition is the product's, untouched. A still cannot show the motion or the spinner; nothing about them changes.
- **Blocks screens** (`screens/*.json`): Today, Board, route, send, Log and Settings are Blocks screens built only from core kinds (screen, sheet, section, list, row, stat, chips, chart, button, form), plus two app kinds: `board` (the lit board) and `mascot`.
- **Live screens** (session, Force, watch) are SwiftUI on Blocks' look: the same palette, tiles and stat/chips blocks.
- **Theme:** Sendmeter's chalk/slate palette and indigo primary, handed to Blocks as its palette, with 18 pt rounded tiles and no dot grid. No swag theme pack.
- **No prose:** every label is a noun or a verb. Empty, error and onboarding states are not drawn in this round.

## Render

`./render.sh` (all screens) or `./render.sh board` (one) builds the preview tool and writes `png/`. The tool pins Blocks at `staging` e823e0b.
