#!/usr/bin/env python3
"""#1032 evidence harness (LOCAL ONLY, never committed into Sources).

Applies #1031's capture harness (`issue-1031/tools/apply-harness.py`: the
DEBUG `--design-1028 <state>` fixture over the real `MainTabView`) and then
adds the #1032 states, so the same harness renders both the base (before)
and the lane head (after):

  dashboard              readiness 38, load ratio 0.66, 2 scored days
                         (the approved #1022 cell recover/under + #1023 sparse)
  dashboard-maintain     readiness 55, ratio 0.85, 14 scored days (maintain/optimal, dense trend)
  dashboard-push-high    readiness 85, ratio 1.38, 14 scored days (push/high, dense trend)
  `--design-1028-scroll zone`  Force scrolls its Training balance card into view

Usage: apply-harness.py <repo-root>    (then `just gen` in that checkout)
"""
import pathlib
import runpy
import sys

repo = pathlib.Path(sys.argv[1])
here = pathlib.Path(__file__).resolve().parent
runpy.run_path(str(here.parents[1] / "issue-1031/tools/apply-harness.py"), run_name="__main__")

root = repo / "native/SendmeterNative/Sources"


def splice(rel, anchor, new):
    path = root / rel
    text = path.read_text()
    assert text.count(anchor) == 1, f"{rel}: anchor not unique: {anchor!r}"
    path.write_text(text.replace(anchor, new))


fx = "App/DesignFixture1028.swift"
splice(fx, "        case dashboard\n", '        case dashboard\n        case dashboardMaintain = "dashboard-maintain"\n        case dashboardPushHigh = "dashboard-push-high"\n')
splice(fx, "            case .dashboard: return .dashboard\n", "            case .dashboard, .dashboardMaintain, .dashboardPushHigh: return .dashboard\n")
splice(fx, "        case .dashboard, .workout, .history, .settings:\n", "        case .dashboard, .dashboardMaintain, .dashboardPushHigh, .workout, .history, .settings:\n")
# Load ratio per state (EWMA, TrainingMetrics.computeACWR): the base pattern
# (four 490-load days a week, days 7-89) plus this week's sessions.
splice(
    fx,
    '        add(5, "fingerboard", "Fingerboard", 55, 6)\n        add(2, "board", "Board Climbing", 95, 7)\n',
    "        switch state {\n"
    "        case .dashboardMaintain?:\n"
    "            for offset in [1, 3, 5, 6] { add(offset, plans[offset % 4].0, plans[offset % 4].1, 70, 7) }\n"
    "        case .dashboardPushHigh?:\n"
    "            for offset in 0...6 { add(offset, plans[offset % 4].0, plans[offset % 4].1, 75, 8) }\n"
    "        default:\n"
    '            add(5, "fingerboard", "Fingerboard", 55, 6)\n'
    '            add(2, "board", "Board Climbing", 95, 7)\n'
    "        }\n",
)
splice(
    fx,
    "            let readiness: Int? = offset == 0 ? 38 : (offset == 13 ? 18 : nil)\n",
    "            let readiness: Int? = {\n"
    "                switch state {\n"
    "                case .dashboardMaintain?: return offset < 14 ? 55 - offset % 3 * 2 : nil\n"
    "                case .dashboardPushHigh?: return offset < 14 ? 85 - offset % 4 * 2 : nil\n"
    "                default: return offset == 0 ? 38 : (offset == 13 ? 18 : nil)\n"
    "                }\n"
    "            }()\n",
)
splice(
    fx,
    '                zone: readiness == nil ? nil : "recover",\n',
    '                zone: readiness.map { $0 < 40 ? "recover" : ($0 > 70 ? "push" : "maintain") },\n',
)
splice(
    fx,
    "    static var scrollsToBottom: Bool {\n",
    "    /// #1032: `--design-1028-scroll zone` brings Force's Training balance\n"
    "    /// card (the #1024 subtitle) into view.\n"
    "    static var scrollsToZoneFocus: Bool {\n"
    "        let args = CommandLine.arguments\n"
    '        guard let index = args.firstIndex(of: "--design-1028-scroll"),\n'
    "              args.indices.contains(index + 1)\n"
    "        else { return false }\n"
    '        return args[index + 1] == "zone"\n'
    "    }\n\n"
    "    static var scrollsToBottom: Bool {\n",
)
fv = "Features/Force/ForceView.swift"
splice(
    fv,
    "                            onPick: armRecommendedZone,\n                            locked: recordingContextLocked\n                        )\n",
    "                            onPick: armRecommendedZone,\n                            locked: recordingContextLocked\n                        )\n"
    '                        .id("design-1032-zone-focus")\n',
)
splice(
    fv,
    "                forceScrollProxy = proxy\n",
    "                forceScrollProxy = proxy\n"
    "                if DesignFixture1028.scrollsToZoneFocus {\n"
    "                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {\n"
    '                        proxy.scrollTo("design-1032-zone-focus", anchor: .center)\n'
    "                    }\n"
    "                }\n",
)
print("#1032 states applied to", root)
