#!/usr/bin/env python3
"""#1031 evidence harness (LOCAL ONLY, never committed into Sources).

Applies the DEBUG `--design-1028 <state>` capture harness (slice 1's
`DesignFixture1028`, plus the #1031 states `force-guided-recording`,
`force-held` and a live-link `force-interrupted`) to a checkout, by anchor,
so the same harness renders both the base (before) and the lane head (after).

Usage: apply-harness.py <repo-root>    (then `just gen` in that checkout)
"""
import base64, gzip, json, pathlib, sys

PAYLOAD = "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"

root = pathlib.Path(sys.argv[1]) / "native/SendmeterNative/Sources"
payload = json.loads(gzip.decompress(base64.b64decode(PAYLOAD)))

(root / "App/DesignFixture1028.swift").write_text(payload["fixture"])
for rel, key in (("App/AppModel.swift", "appmodel"), ("Platform/TindeqBluetooth.swift", "tindeq")):
    path = root / rel
    path.write_text(path.read_text() + payload[key])

def splice(rel, anchor, new):
    path = root / rel
    text = path.read_text()
    assert text.count(anchor) == 1, f"{rel}: anchor not unique"
    path.write_text(text.replace(anchor, new))

splice(
    "App/SendmeterNativeApp.swift",
    '                    if CommandLine.arguments.contains("--error-banner-fixture") {',
    '                    if DesignFixture1028.state != nil {\n'
    '                        DesignFixture1028View()\n'
    '                    } else if CommandLine.arguments.contains("--error-banner-fixture") {',
)
splice(
    "Features/Force/ForceView.swift",
    "                    registerGuidedTeardown(for: guidedSession)\n                }\n",
    "                    registerGuidedTeardown(for: guidedSession)\n                }\n"
    "                #if DEBUG\n"
    "                if let id = DesignFixture1028.armedPresetID, selectedPresetID == nil {\n"
    "                    applySelection(.savedPreset(id))\n"
    "                }\n"
    "                #endif\n",
)
print("harness applied to", root)


def splice_if(rel, anchor, new):
    """Optional splice: only trees that carry the anchor (the lane head has a
    ScrollViewReader; the base does not)."""
    path = root / rel
    text = path.read_text()
    if text.count(anchor) == 1:
        path.write_text(text.replace(anchor, new))
        print("optional splice applied:", rel)


# `@progressor`: scroll Force's device card (home of the #1004 Save / Discard
# controls) to the bottom of the scroll view, i.e. just above the sticky
# bar (the bar inset is part of the scroll content margin), through the
# lane's own ScrollViewReader proxy.
splice_if(
    "Features/Force/ForceView.swift",
    "                            recoverySaveFailed = false\n"
    "                        }\n"
    "                    )\n",
    "                            recoverySaveFailed = false\n"
    "                        }\n"
    "                    )\n"
    "                    .id(\"design-1028-progressor-card\")\n",
)
splice_if(
    "Features/Force/ForceView.swift",
    "            .onAppear {\n                forceScrollProxy = proxy\n            }\n",
    "            .onAppear {\n                forceScrollProxy = proxy\n"
    "                if DesignFixture1028.scrollsToProgressor {\n"
    "                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) {\n"
    "                        proxy.scrollTo(\"design-1028-progressor-card\", anchor: .bottom)\n"
    "                    }\n"
    "                }\n"
    "            }\n",
)
