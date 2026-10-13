# #1028 tokens — the one shared Sendmeter palette

Generated from `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SendmeterPalette.swift`
by `design-output/1028/tools/tokens.sh` — do not hand-edit. The Watch is
dark-only and paints the **Dark** column, so phone-dark and Watch are the same
palette (B1). A gate test fails on any colour literal outside the token files
(B2); every text pair below is also asserted in `SendmeterPaletteContrastTests` (B3).

## Tokens

| Token | Light | Dark (= Watch) | Use |
|---|---|---|---|
| `canvas` | `#F3F3F7` | `#0B0C12` | Screen background; Watch canvas |
| `surface` | `#FFFFFF` | `#17181F` | Card (`SurfaceCard`, `WatchCard`) |
| `surfaceRaised` | `#F7F7FA` | `#22232C` | Nested: protocol hero, load module, trace chart |
| `surfaceNested` | `#ECECF2` | `#2B2C36` | Second nesting level |
| `surfaceDisabled` | `#E8E8ED` | `#2A2B33` | Disabled control fill |
| `line` | `#D8D8DE` | `#363743` | Hairlines, dividers |
| `grid` | `#E2E2E6` | `#30313B` | Chart gridlines (incl. the F4 kg scale) |
| `textPrimary` | `#15161C` | `#F4F4F8` | Primary text |
| `textSecondary` | `#52525C` | `#B9BAC6` | Secondary text, metadata |
| `textTertiary` | `#696974` | `#9A9BA8` | Axis labels, timestamps |
| `textDisabled` | `#61616B` | `#9E9FAA` | Disabled labels |
| `primaryText` | `#4A4EAC` | `#A9ADE3` | Brand-tinted text on neutral surfaces |
| `primarySoft` | `#C3C5EC` | `#3A3D7A` | Selected chip / soft fill |
| `onPrimary` | `#FFFFFF` | `#FFFFFF` | Label on a filled primary button |
| `onCaution` | `#1A1A1A` | `#1A1A1A` | Label on the amber rest stage |
| `primary` | `#5B5FC7` | `#5B5FC7` | Brand hue (buttons, focus) |
| `optimal` | `#2E96F0` | `#2E96F0` | Optimal / success marks |
| `caution` | `#DDB13A` | `#DDB13A` | Caution marks, rest stage |
| `danger` | `#E5743A` | `#E5743A` | Danger marks |
| `execution` | `#7B83EB` | `#7B83EB` | Execution / recording marks |
| `paused` | `#565D6D` | `#7D8496` | Paused / offline dot (neutral) |
| `optimalText` | `#216CAD` | `#4FB0FF` | Optimal as small text |
| `cautionText` | `#7E6521` | `#E8C24E` | Caution as small text |
| `dangerText` | `#A35229` | `#F0864C` | Danger as small text |
| `executionText` | `#5C62B0` | `#9296EE` | Execution as small text |
| `success` | `#2E96F0` | `#4FB0FF` | Ready state (Watch now = phone blue, was mint) |
| `watchForceNav` | `#FF6EC2` | `#FF6EC2` | Watch Force nav card only (#538 deviation) |
| `zonePower` | `#E5743A` | `#E5743A` | Zone: power |
| `zoneStrength` | `#DDB13A` | `#DDB13A` | Zone: strength |
| `zonePowerEndurance` | `#87669A` | `#A88BBB` | Zone: power-endurance |
| `zoneEndurance` | `#3CBFA3` | `#3CBFA3` | Zone: endurance |

## Text contrast (WCAG 2.x, sRGB relative luminance)

Minimum 4.5:1 for text, 3.0:1 for large/bold labels and glyphs. "chalked"
rows are the A1 worst case: a full-strength chalk grain (`textPrimary` at
`chalkOpacity` = 0.05) directly behind the glyph, on the few
chalked hero surfaces (Today's decision, the armed protocol).

| Pair | Min | Light | Dark (= Watch) | |
|---|---|---|---|---|
| textPrimary on canvas | 4.50 | 16.31 | 17.80 | AA |
| textSecondary on canvas | 4.50 | 6.98 | 10.14 | AA |
| textTertiary on canvas | 4.50 | 4.90 | 7.09 | AA |
| primaryText on canvas | 4.50 | 6.37 | 9.09 | AA |
| textPrimary on surface | 4.50 | 18.05 | 16.13 | AA |
| textSecondary on surface | 4.50 | 7.72 | 9.19 | AA |
| textTertiary on surface | 4.50 | 5.42 | 6.43 | AA |
| primaryText on surface | 4.50 | 7.05 | 8.23 | AA |
| textPrimary on surfaceRaised | 4.50 | 16.88 | 14.23 | AA |
| textSecondary on surfaceRaised | 4.50 | 7.22 | 8.11 | AA |
| textTertiary on surfaceRaised | 4.50 | 5.07 | 5.67 | AA |
| primaryText on surfaceRaised | 4.50 | 6.60 | 7.27 | AA |
| textPrimary on surfaceNested | 4.50 | 15.34 | 12.62 | AA |
| textSecondary on surfaceNested | 4.50 | 6.56 | 7.19 | AA |
| textTertiary on surfaceNested | 4.50 | 4.61 | 5.03 | AA |
| primaryText on surfaceNested | 4.50 | 6.00 | 6.45 | AA |
| textSecondary on chalked surface | 4.50 | 6.96 | 8.12 | AA |
| textTertiary on chalked surface | 4.50 | 4.89 | 5.68 | AA |
| primaryText on chalked surface | 4.50 | 6.36 | 7.28 | AA |
| textSecondary on chalked surfaceRaised | 4.50 | 6.55 | 7.08 | AA |
| textTertiary on chalked surfaceRaised | 4.50 | 4.60 | 4.95 | AA |
| primaryText on chalked surfaceRaised | 4.50 | 5.98 | 6.35 | AA |
| pill primary on canvas | 4.50 | 8.54 | 8.67 | AA |
| pill primary on surface | 4.50 | 9.40 | 7.71 | AA |
| pill primary on surfaceRaised | 4.50 | 8.84 | 6.82 | AA |
| pill primary on surfaceNested | 4.50 | 8.08 | 6.09 | AA |
| pill primary on chalked surface | 4.50 | 8.53 | 6.84 | AA |
| pill primary on chalked surfaceNested | 4.50 | 7.33 | 5.31 | AA |
| pill optimal on canvas | 4.50 | 6.77 | 9.85 | AA |
| pill optimal on surface | 4.50 | 7.41 | 8.73 | AA |
| pill optimal on surfaceRaised | 4.50 | 6.97 | 7.62 | AA |
| pill optimal on surfaceNested | 4.50 | 6.41 | 6.78 | AA |
| pill optimal on chalked surface | 4.50 | 6.76 | 7.64 | AA |
| pill optimal on chalked surfaceNested | 4.50 | 5.83 | 5.91 | AA |
| pill caution on canvas | 4.50 | 5.45 | 11.32 | AA |
| pill caution on surface | 4.50 | 6.00 | 9.93 | AA |
| pill caution on surfaceRaised | 4.50 | 5.65 | 8.62 | AA |
| pill caution on surfaceNested | 4.50 | 5.17 | 7.64 | AA |
| pill caution on chalked surface | 4.50 | 5.45 | 8.64 | AA |
| pill caution on chalked surfaceNested | 4.50 | 4.71 | 6.64 | AA |
| pill danger on canvas | 4.50 | 6.78 | 9.95 | AA |
| pill danger on surface | 4.50 | 7.42 | 8.75 | AA |
| pill danger on surfaceRaised | 4.50 | 6.98 | 7.65 | AA |
| pill danger on surfaceNested | 4.50 | 6.42 | 6.80 | AA |
| pill danger on chalked surface | 4.50 | 6.77 | 7.66 | AA |
| pill danger on chalked surfaceNested | 4.50 | 5.83 | 5.99 | AA |
| pill execution on canvas | 4.50 | 7.03 | 9.89 | AA |
| pill execution on surface | 4.50 | 7.68 | 8.70 | AA |
| pill execution on surfaceRaised | 4.50 | 7.22 | 7.57 | AA |
| pill execution on surfaceNested | 4.50 | 6.59 | 6.78 | AA |
| pill execution on chalked surface | 4.50 | 7.01 | 7.59 | AA |
| pill execution on chalked surfaceNested | 4.50 | 6.04 | 5.93 | AA |
| pill paused on canvas | 4.50 | 9.26 | 9.72 | AA |
| pill paused on surface | 4.50 | 10.22 | 8.57 | AA |
| pill paused on surfaceRaised | 4.50 | 9.60 | 7.47 | AA |
| pill paused on surfaceNested | 4.50 | 8.76 | 6.63 | AA |
| pill paused on chalked surface | 4.50 | 9.24 | 7.49 | AA |
| pill paused on chalked surfaceNested | 4.50 | 7.94 | 5.85 | AA |
| pill zonePowerEndurance on canvas | 4.50 | 8.18 | 10.30 | AA |
| pill zonePowerEndurance on surface | 4.50 | 9.02 | 9.03 | AA |
| pill zonePowerEndurance on surfaceRaised | 4.50 | 8.48 | 7.93 | AA |
| pill zonePowerEndurance on surfaceNested | 4.50 | 7.73 | 7.04 | AA |
| pill zonePowerEndurance on chalked surface | 4.50 | 8.16 | 7.96 | AA |
| pill zonePowerEndurance on chalked surfaceNested | 4.50 | 7.02 | 6.13 | AA |
| pill zoneEndurance on canvas | 4.50 | 5.85 | 10.81 | AA |
| pill zoneEndurance on surface | 4.50 | 6.40 | 9.45 | AA |
| pill zoneEndurance on surfaceRaised | 4.50 | 6.02 | 8.21 | AA |
| pill zoneEndurance on surfaceNested | 4.50 | 5.54 | 7.27 | AA |
| pill zoneEndurance on chalked surface | 4.50 | 5.84 | 8.22 | AA |
| pill zoneEndurance on chalked surfaceNested | 4.50 | 5.04 | 6.40 | AA |
| textDisabled on surfaceDisabled | 4.50 | 5.01 | 5.36 | AA |
| onPrimary on primary (button label) | 4.50 | 5.38 | 5.38 | AA |
| onCaution on caution (rest stage) | 4.50 | 8.64 | 8.64 | AA |
| optimalText on surface | 4.50 | 5.51 | 7.57 | AA |
| optimalText on surfaceRaised | 4.50 | 5.15 | 6.68 | AA |
| cautionText on surface | 4.50 | 5.57 | 10.33 | AA |
| cautionText on surfaceRaised | 4.50 | 5.21 | 9.12 | AA |
| dangerText on surface | 4.50 | 5.53 | 6.93 | AA |
| dangerText on surfaceRaised | 4.50 | 5.17 | 6.11 | AA |
| executionText on surface | 4.50 | 5.48 | 6.59 | AA |
| executionText on surfaceRaised | 4.50 | 5.13 | 5.81 | AA |

Tightest margins: light — textTertiary on chalked surfaceRaised (+0.10); dark — textTertiary on chalked surfaceRaised (+0.45).
