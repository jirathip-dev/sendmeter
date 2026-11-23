# Design recipe — Sendmeter (Blocks screens on the crag pack)

Every Sendmeter design lane builds its mockups on Blocks. A screen is a Blocks
`screen` (or `sheet`) JSON fixture that Blocks' own HTML renderer draws, with
the crag pack's stylesheet on top. Blocks' headless harness renders it to PNGs.
Don't hand-build HTML, CSS or fonts: the look comes from the pack.

- medium: Blocks screens: `screen`/`sheet` JSON fixtures, drawn by Blocks' HTML renderer under the pinned crag pack
- folder: docs/design
- render: `cd docs/design/<slug> && blocks check && blocks check --shot <screen>` (one `--shot` per screen; writes `shots/390/<screen>/<screen>.png` and `shots/1440/<screen>/<screen>.png`)
- sizes: 1440 and 390 wide (`blocks check --shot` draws 390x844 and 1440x900)
- clip: no
- tools: webkit

## Pins

| What | Pin | Where it is read |
|---|---|---|
| blocks (renderer, `blocks check`, the `blocks-shot` harness) | release `v2.0`, commit `b1a9c9916efc5144a791aaca50d401c077a27501` | `https://github.com/jirathip-dev/blocks` |
| swag | commit `8964e64b8869cf9dc892819e172305cb6c601adc` | `https://github.com/jirathip-dev/swag` |
| crag pack (stylesheet and fonts) | `issue-1060` at commit `f7e3aa206078ebe353869114b880d6b052a3a39c`: `docs/design/crag/pack/crag.css` and `docs/design/crag/fonts/` | this repo, until swag carries `packs/crag/` |

Swag at its pin has no crag pack yet (farm, garden, kitchen). When crag lands in
swag, move the swag pin to that commit, read the pack from swag's `packs/crag/`
and drop the `issue-1060` row. One pin change, not two sources.

## Setup (once per lane, everything under `$DROVER_SCRATCH_TARGET`)

```bash
export BLOCKS_SRC="$DROVER_SCRATCH_TARGET/blocks"
git clone --quiet --depth 1 --branch v2.0 https://github.com/jirathip-dev/blocks "$BLOCKS_SRC"
test "$(git -C "$BLOCKS_SRC" rev-parse HEAD)" = b1a9c9916efc5144a791aaca50d401c077a27501
CARGO_TARGET_DIR="$DROVER_SCRATCH_TARGET/target" cargo install --locked --path "$BLOCKS_SRC/crates/blocks-cli" --root "$DROVER_SCRATCH_TARGET/blocks-bin"
(cd "$BLOCKS_SRC/web" && PLAYWRIGHT_SKIP_BROWSER_DOWNLOAD=1 npm ci --ignore-scripts)
export PATH="$DROVER_SCRATCH_TARGET/blocks-bin/bin:$PATH"
```

`cargo` comes from the toolchain blocks pins in `rust-toolchain.toml`. The
harness launches Playwright's WebKit (the host's `webkit` tag); a host without
it ends the lane `blocked` before it starts.

## The design folder

`docs/design/<slug>/` holds:

- `screens/<screen>.json`: one Blocks fixture per screen, at most 3 unless the
  issue asks for variants. Start from `docs/design/blocks-example/` and the
  usage skill (`blocks skill --to "$DROVER_SCRATCH_TARGET/skill"`).
- `.blocks/guard.json`: the guard's config for this folder. Copy the example's
  and add the pack to `css`:
  `"css": ["pack/fonts/fonts.css", "pack/crag.css"]`.
- `pack/`: `crag.css` and `fonts/` copied from the crag pin above, from
  inside the folder:

  ```bash
  CRAG=f7e3aa206078ebe353869114b880d6b052a3a39c
  git fetch --quiet origin "$CRAG"
  mkdir -p pack/fonts
  git show "$CRAG:docs/design/crag/pack/crag.css" > pack/crag.css
  for f in $(git ls-tree --name-only "$CRAG" docs/design/crag/fonts/); do git show "$CRAG:$f" > "pack/fonts/${f##*/}"; done
  ```
- `shots/`: what the render step writes; the README maps each PNG.
- `README.md`: the design lane's summary and image map.

The guard runs from inside the folder, so it checks only this design's
screens: `blocks check` must exit 0 before the shots are taken, and a design
with a finding is not done.

## Missing kinds

When Blocks can't draw something yet (a kind, a field, a look):

1. Draw it as a clearly marked stand-in: an `island` block with a `size` and a
   `fallback.title` that starts `Stand-in:` and names what it stands for, so the
   PNG shows the tag (the example's moon gauge).
2. File it in `jirathip-dev/blocks` as its own issue, one per missing kind,
   with the screen that needs it and what it must show.
3. List each stand-in and its blocks issue in the design's README.

Never fake a missing kind with hand-built HTML or CSS outside a stand-in.
