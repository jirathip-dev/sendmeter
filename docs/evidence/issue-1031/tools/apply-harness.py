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
