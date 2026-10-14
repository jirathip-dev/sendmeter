// #1028 B3 (rollout #1030) — generates docs/design/tokens.md from the REAL palette.
//
// Compiled together with the shipped Foundation-only sources, so the table
// can never drift from the code (tokens.sh does the compile + diff check):
//   SendLogWatchCore/SendmeterPalette.swift   (the one shared palette)
//   SendLogWatchCore/WatchDesign.swift        (SendmeterSemanticHue)
//   SendLogWatchCore/WorkoutPhaseFill.swift   (PhaseRGB WCAG maths)
import Foundation

typealias P = SendmeterPalette

func fmt(_ v: Double) -> String { String(format: "%.2f", v) }

let tokens: [(String, P.Pair, String)] = [
    ("canvas", P.canvas, "Screen background; Watch canvas"),
    ("surface", P.surface, "Card (`SurfaceCard`, `WatchCard`)"),
    ("surfaceRaised", P.surfaceRaised, "Nested: protocol hero, load module, trace chart"),
    ("surfaceNested", P.surfaceNested, "Second nesting level"),
    ("surfaceDisabled", P.surfaceDisabled, "Disabled control fill"),
    ("line", P.line, "Hairlines, dividers"),
    ("grid", P.grid, "Chart gridlines (incl. the F4 kg scale)"),
    ("textPrimary", P.textPrimary, "Primary text"),
    ("textSecondary", P.textSecondary, "Secondary text, metadata"),
    ("textTertiary", P.textTertiary, "Axis labels, timestamps"),
    ("textDisabled", P.textDisabled, "Disabled labels"),
    ("primaryText", P.primaryText, "Brand-tinted text on neutral surfaces"),
    ("primarySoft", P.primarySoft, "Selected chip / soft fill"),
    ("onPrimary", P.onPrimary, "Label on a filled primary button"),
    ("onCaution", P.onCaution, "Label on the amber rest stage"),
    ("primary", P.primary, "Brand hue (buttons, focus)"),
    ("optimal", P.optimal, "Optimal / success marks"),
    ("caution", P.caution, "Caution marks, rest stage"),
    ("danger", P.danger, "Danger marks"),
    ("execution", P.execution, "Execution / recording marks"),
    ("paused", P.paused, "Paused / offline dot (neutral)"),
    ("optimalText", P.optimalText, "Optimal as small text"),
    ("cautionText", P.cautionText, "Caution as small text"),
    ("dangerText", P.dangerText, "Danger as small text"),
    ("executionText", P.executionText, "Execution as small text"),
    ("success", P.success, "Ready state (Watch now = phone blue, was mint)"),
    ("watchForceNav", P.watchForceNav, "Watch Force nav card only (#538 deviation)"),
    ("zonePower", P.zonePower, "Zone: power"),
    ("zoneStrength", P.zoneStrength, "Zone: strength"),
    ("zonePowerEndurance", P.zonePowerEndurance, "Zone: power-endurance"),
    ("zoneEndurance", P.zoneEndurance, "Zone: endurance"),
    ("rest", P.rest, "Resting hue: phone RESTING accent + Watch rest-target chips (P6)"),
    ("chartReference", P.chartReference, "Chart reference marks (`ChartToken.reference`)"),
    ("chartGrid", P.chartGrid, "Chart gridlines (`ChartToken.grid`)"),
    ("chartAxis", P.chartAxis, "Chart axis labels (`ChartToken.axis`)"),
    ("chartTooltip", P.chartTooltip, "Chart tooltip fill"),
    ("chartTooltipBorder", P.chartTooltipBorder, "Chart tooltip border"),
    ("activityBoard", P.activityBoard, "Activity: board"),
    ("activityFingerboard", P.activityFingerboard, "Activity: fingerboard"),
    ("activityGym", P.activityGym, "Activity: gym"),
    ("activityOutdoor", P.activityOutdoor, "Activity: outdoor"),
    ("activityArc", P.activityArc, "Activity: ARC"),
    ("activityAntagonist", P.activityAntagonist, "Activity: antagonist"),
    ("activityRoutine", P.activityRoutine, "Activity: routine"),
    ("activityCampus", P.activityCampus, "Activity: campus"),
    ("activityTindeq", P.activityTindeq, "Activity: Tindeq"),
    ("activityAuto", P.activityAuto, "Activity: auto-detected"),
    ("activityCustom", P.activityCustom, "Activity: custom"),
]

var out = """
# #1028 tokens — the one shared Sendmeter palette

Generated from `ios/App/SendLogWatchCore/Sources/SendLogWatchCore/SendmeterPalette.swift`
by `docs/evidence/issue-1030/tools/tokens.sh` — do not hand-edit. The Watch is
dark-only and paints the **Dark** column, so phone-dark and Watch are the same
palette (B1). A gate test fails on any colour literal outside the token files
(B2); every text pair below is also asserted in `SendmeterPaletteContrastTests` (B3).

## Tokens

| Token | Light | Dark (= Watch) | Use |
|---|---|---|---|

"""
for (name, pair, use) in tokens {
    out += "| `\(name)` | `\(pair.light)` | `\(pair.dark)` | \(use) |\n"
}

out += """

## Text contrast (WCAG 2.x, sRGB relative luminance)

Minimum 4.5:1 for text, 3.0:1 for large/bold labels and glyphs. "chalked"
rows are the A1 worst case: a full-strength chalk grain (`textPrimary` at
`chalkOpacity` = \(P.chalkOpacity)) directly behind the glyph, on the few
chalked hero surfaces (Today's decision, the armed protocol).

| Pair | Min | Light | Dark (= Watch) | |
|---|---|---|---|---|

"""
var failures = 0
var worstLight = (name: "", value: 99.0)
var worstDark = (name: "", value: 99.0)
for pair in P.textPairs {
    let light = pair.ratio(isDark: false)
    let dark = pair.ratio(isDark: true)
    let ok = light >= pair.minimum && dark >= pair.minimum
    if !ok { failures += 1 }
    if light - pair.minimum < worstLight.value { worstLight = (pair.name, light - pair.minimum) }
    if dark - pair.minimum < worstDark.value { worstDark = (pair.name, dark - pair.minimum) }
    out += "| \(pair.name) | \(fmt(pair.minimum)) | \(fmt(light)) | \(fmt(dark)) | \(ok ? "AA" : "**FAIL**") |\n"
}

out += """

Tightest margins: light — \(worstLight.name) (+\(fmt(worstLight.value))); dark — \(worstDark.name) (+\(fmt(worstDark.value))).

"""

let path = CommandLine.arguments.dropFirst().first ?? "tokens.md"
try! out.write(toFile: path, atomically: true, encoding: .utf8)
print("wrote \(path) — \(P.textPairs.count) text pairs, \(failures) failing")
exit(failures == 0 ? 0 : 1)
