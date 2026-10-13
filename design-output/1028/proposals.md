# #1028 proposals (A2): owner accepts or rejects each

The owner invited improvements beyond the locked spec. **None of these ships
unapproved.** Items marked *in prototype* are visible in this round's
screenshots so they can be judged in context. Turning one down reverts only
that item. Everything else is either the locked spec or deliberately left out.

| # | Proposal | Why | Where to see it | In prototype? | Owner |
|---|---|---|---|---|---|
| P1 | **Mid-pull, the recording-context card shrinks to one locked line** ("FDP · Side Left · Free pull — Locked until this pull is saved"). | While a pull runs, nothing on that card can change. At full height it pushed the live trace under the bar on a 17 Pro. | `sheets/17pro-force-recording.png`, `sheets/se-force-recording.png` | yes | ☐ accept ☐ reject |
| P2 | **Hands-free armed: the card says "Free pull", not "Nothing armed".** | The bar said "Armed · pull to start" while the card said "Nothing armed". In Hands-free the free pull *is* the plan. | `sheets/17pro-force-handsfree-armed.png` | yes | ☐ accept ☐ reject |
| P3 | **Disconnected: the card header says "Selected protocol", and "Armed protocol" only with a live link.** | Extends F3 to the header: without a Progressor, nothing is armed yet. | `sheets/17pro-force-disconnected.png` vs `…-guided-armed.png` | yes | ☐ accept ☐ reject |
| P4 | **A 14 pt fade above the tab bar and the Force bar** (on top of F5's clearance). | Content moving behind the bars dissolves rather than being sliced at a hard line. F5 still guarantees the last row ends above the bars. | any `sheets/*-bottom.png` | yes | ☐ accept ☐ reject |
| P5 | **The mascot prop is a carabiner, not a chalk bag or hangboard.** | At the sizes the mascots render in-app (72–122 pt), a chalk-bag silhouette read as a jar or pot in every test. A hangboard needs a wall. A carabiner reads at any size. | `mascots/mascot-sheet.png`, `sheets/mascot-in-app.png` | candidate assets only (see C below) | ☐ accept ☐ reject |
| P6 | **Unify the Watch rest-picker ramp** (`restRamp60…240`) with the phone's rest-stage hues in the rollout. | It is the last Watch colour family that the phone never paints. It is kept as shipped here because a Watch screenshot test pins its cyan. | `tokens.md` (restRamp rows) | no, rollout only | ☐ accept ☐ reject |
| P7 | **Extend the chalk texture to the Watch force gauge's hero ring** in the rollout. | It would carry the climbing feel to the Watch. Left out of this round because A1 says "a few hero surfaces" and the Watch is already at its contrast floor. | none | no | ☐ accept ☐ reject |
| P8 | **A locked mode switch stays readable**: mid-pull or armed, the switch collapses to the chosen mode as an outlined neutral chip with a lock glyph (textPrimary on surfaceNested, AA), instead of the whole control fading. | Fading to 55 % left white on washed-out primary at roughly 1:1. A disabled plain button also dims its label, measured at 3.46:1 on the SE. Dropping the unpickable segment frees room so "Armed · pull to start" fits on an SE. | `sheets/se-force-recording.png`, `sheets/se-force-handsfree-armed.png` | yes | ☐ accept ☐ reject |
| P9 | **Compact phones: mid-pull, keep the live trace on screen.** On an iPhone SE the large title, context line and readout push most of the trace chart below the bar at the resting scroll position. The trace is clipped cleanly (F5 holds) but hidden until you scroll. Options: collapse the large title while recording, or shorten the chart on compact heights. | On a 17 Pro the full chart fits above the bar. On an SE about half of it is below the fold during a pull. | `sheets/se-force-recording.png` | **no** (not built) | ☐ accept ☐ reject |
| P10 | **Drop the "Identity dot · tap to arm" caption** above the protocol tiles, or replace it with "Tap to arm". | Same pattern as #1024: it describes how the UI is built. The coloured dot and the tiles already say it. It comes from #903 and is not one of the two strings #1024 names, so it is not changed here. | `sheets/se-force-guided-idle.png` | **no** | ☐ accept ☐ reject |
| P11 | **Interrupted, say so.** The interrupted state currently looks the same as disconnected (bar "Disconnected · Reconnect", card "Waiting for Progressor"). A bar status like "Connection lost" would tell the climber the pull was cut, not just that nothing is paired. | F3 is honest (nothing live is claimed), but it doesn't explain the interruption. One word for the state (D) argues for keeping "Disconnected", so this is the owner's call. | `sheets/17pro-force-interrupted.png` | **no** | ☐ accept ☐ reject |

## Deliberately NOT done (scope guard)

- No layout changes beyond D/F. Cards, order and information architecture are as in build 57.
- The approved mascot masters (`ForceMascotLarge`, `WorkoutMascotLarge`) are **byte-identical**: the
  refined versions are separate candidate assets, shown only with `--design-1028-mascots refined`.
- `watchForceNav` #FF6EC2 is kept: it is a maintainer-accepted deviation recorded on #538.
