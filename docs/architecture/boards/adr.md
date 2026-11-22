# ADR: Board tab — route sources, catalogue store, lighting, setup (#1047)

## Summary

Decision: Sendmeter never talks to a board maker's servers. Kilter left Aurora in March 2026, and both Aurora's (Tension) and Kilter's terms forbid third-party access. Setup, lighting, your own routes and sends work on all three boards with no outside service. The Kilter and Tension catalogue comes from the public route files the Boardsesh project publishes, downloaded on the phone when the user asks. MoonBoard routes are entered by the user.
Slices: a pure board package (types, both lighting protocols, connection logic); the Bluetooth link; MoonBoard end to end; then, behind the owner gate, the board hardware map, the catalogue download and search, and the release paperwork. Twelve issues.
Open questions: (1) Owner gate: approve the Boardsesh route files as the Kilter and Tension catalogue (recommended, can be per board), or ship user-entered routes only until a maker gives permission? (2) MoonBoard catalogue from the same files: off in v1 (recommended; Moon says it does not share its data) or on?

Status: proposed, 2026-11-22. This is an engineering risk assessment, not legal advice.

## Question

How does Sendmeter get routes for Kilter, Tension and MoonBoard, keep them on the device, light them
over Bluetooth LE, and log sends, without breaking the makers' terms or failing App Review?

## What the research found

The issue assumed Kilter and Tension both run on Aurora's sync API. That is no longer true.

### The platforms today

- **Kilter left Aurora.** On 2026-03-26 Aurora switched off the Kilter server and removed its Kilter app.
  The old host now redirects to a domain-sale page (checked 2026-11-22). Kilter runs its own app and
  backend ([Climbing, 2026-03-31](https://www.climbing.com/news/why-the-kilter-board-app-suddenly-disappeared/)).
  The two companies are in court in British Columbia (*Aurora Climbing Inc. v. Kilter, LLC*,
  2026 BCSC 290). Aurora alleges Kilter reverse engineered its controller technology in breach of
  Aurora's 2023 terms; the court refused Aurora an injunction in February 2026.
- **Tension is still an Aurora app.** The Aurora sync API still serves it.
- **Aurora acts against third-party clients.** In June 2025 the maintainers of Boardsesh and of
  Climbdex/BoardLib reported emails from Aurora demanding removal and threatening legal action
  ([Climbdex#101](https://github.com/lemeryfertitta/Climbdex/issues/101)). Aurora changed its API
  twice in the same weeks. No lawsuit or DMCA notice against them was found.
- **Boardsesh is on the App Store** (since 2026-04-06) and Google Play, lighting all three boards and
  showing their catalogues. Its name has no board mark; its description says "Works with Kilter,
  Tension, MoonBoard…" and "not affiliated with or endorsed by any board manufacturer".

### The terms

| Maker | Document | What it says | Verdict for a direct client |
|---|---|---|---|
| Aurora (Tension) | [Terms of Use](https://tensionboardapp2.com/terms-of-use), updated 2023-02-27, BC law | "You may only connect to the Aurora Products using the Services, as provided through the Apps". No reverse engineering. No "network analyzer or packet sniffer … to intercept, decode, mine or display any packets". No access "to build a competitive product or service". Users grant Aurora a *non-exclusive* licence to their climbs. Logging in sends an explicit acceptance of these terms. | **Forbidden** |
| Kilter | [Terms](https://kilterboard.io/terms), updated 2026-03-09, Colorado | Do not "try to access [the Services] using a method other than the interface and the instructions that we provide, or extensively or automatically copy any content from the Services (in other words, no scraping)". Personal non-commercial use only. No right to "the Kilter name and logo". No public API. | **Forbidden** |
| Moon (MoonBoard) | No app terms or content licence found (site terms are shop terms; the iOS app uses Apple's standard EULA, which bars reverse engineering the app). [FAQ](https://moonclimbing.com/using-moonboard-app): "Can i have access to the moonboard dataset? — No - we do not share our user data. Please don't ask!" | No public API; the app API needs a login. | **Not offered** |

So the owner gate in the issue applies: **the terms forbid a direct client for both Tension and Kilter.**

### What is openly published

- **Boardsesh's snapshot files.** Boardsesh publishes SQLite files of the climb catalogues it holds,
  one per board and layout, rebuilt nightly and found through a
  [manifest](https://snapshots.boardsesh.com/board-snapshots/v1-gzip/manifest.json). Its
  [LEGAL.md](https://github.com/boardsesh/boardsesh/blob/main/LEGAL.md) says: "The nightly board
  snapshots are public SQLite files of the climb catalogs, cheap for us to serve, and you are welcome
  to use them." It asks consumers to attribute setters, not to present the data as official, and not to
  refetch unchanged files. Its *hosted backend* is closed to other apps; the snapshot files are not.
  On 2026-11-22 the manifest listed Kilter (392,299 climbs in the main layout, 85 MB to download),
  Tension (three layouts, 6 to 12 MB each) and MoonBoard (seven layouts). A second file carries the
  hardware map for every board (holes, placements, LED positions, sizes, hold sets, role colours,
  grade scale): 36 MB to download.
- **The lighting protocols.** Both wire formats are documented in public (Boardsesh's specs under
  Apache-2.0; several MoonBoard LED projects). `protocols.md` restates the facts.
- **Trademarks.** MOONBOARD (US Reg. 5758089) and KILTER (US Reg. 7718567) are registered; KILTER BOARD
  is allowed, not yet registered; no "Tension Board" filing was found.

## Options

| | Option | For | Against |
|---|---|---|---|
| A | Direct client: Aurora's sync API for Tension, Kilter's new API for Kilter, with the user's login | Freshest data; could import the user's old logbook | Both terms forbid it. Needs the user's maker password. Aurora has threatened developers for exactly this and breaks its API on purpose. A reverse-engineered client per maker to maintain. |
| B | Boardsesh's public snapshot files, downloaded on the device | No contact with any maker's service and no maker login, so no maker terms are accepted by Sendmeter. No sync client: a refresh is "download the new file". One adapter for every board. | The data still began as the makers' users' climbs; a maker can dispute it. Depends on a volunteer project that Aurora wants gone. No authorization to show Apple. |
| C | No catalogue: users enter routes themselves on every board | No third-party data at all | Weakest product for Kilter and Tension, where the catalogue is the point. Kilter and Tension still need a hardware map from somewhere to light a hold. |
| D | Ask the makers for permission, build nothing until then | Cleanest | Unknown wait; Aurora's stated position is "firmly against". |
| E | Bundle a catalogue copy in the app, or host one ourselves | Works offline at first launch | Puts third-party data in the App Store binary (guideline 5.2) or needs a server the owner ruled out. |

## Decision

1. **No maker service, ever.** No request goes to Aurora's or Kilter's or Moon's servers; no maker
   login is asked for; nothing is written back to a maker account. (Rules out A.)
2. **Routes come from two sources behind one seam.** `user` routes work on every board with no
   network. `catalogue` routes come from an importer that reads a snapshot file into Sendmeter's own
   database. The seam is the importer: a different source later (a maker's permission, a new file
   format) replaces one type and nothing above it.
3. **Catalogue per board is a compile-time allow-list.** Recommended for v1: Kilter and Tension on
   (option B), MoonBoard off (option C for MoonBoard, as the issue asks when nothing is lawfully
   offered). The owner can turn any board off, or MoonBoard on, by answering the open questions.
4. **Build order puts the ungated work first.** The pure package, the Bluetooth link, and MoonBoard end
   to end use no third-party data and start on approval. The hardware map and the catalogue (issues 9
   to 11) wait for the owner's answer to question 1.
5. **The catalogue lives outside the user's data.** One SQLite file per board layout plus one small
   hardware-map file, in Application Support, excluded from backup, never synced to iCloud. A refresh
   builds a new file and swaps it in whole, so it is idempotent and a failed refresh leaves the old
   catalogue working. Refresh runs when the user asks, or at most weekly on an unmetered network when
   the manifest shows a newer build. The app identifies itself honestly in its user agent.
6. **Lighting is a pure package.** `BoardCore` (Foundation only) holds both encoders and the
   connection state machine, tested on the host and on Linux. One CoreBluetooth class serves both board
   families, since both are a write-only Nordic UART link. It is written from the protocol facts in
   `protocols.md`; no code is copied from the GPL MoonBoard projects.
7. **Setup is one user record per wall.** `BoardSetup` holds the board, its geometry (layout, size and
   hold sets for Kilter and Tension; grid size for MoonBoard) and the current angle. The angle is
   changed from the route list on an adjustable wall and is stored on every send. The Bluetooth
   peripheral and the "current wall" pointer are device-local.
8. **A send is a logbook record.** It carries a snapshot of the route (name, setter, holds, grade at
   that angle), so the logbook survives a catalogue refresh, deletion or loss of the source. It links
   to the session by `sessionID` when a workout is live.
9. **The board is drawn, not pictured.** Screens render holds from coordinates. No maker photo, hold
   image or logo is shipped or downloaded.

Details: `data-shapes.md`, `statecharts.md`, `protocols.md`; modules and issues in `README.md`.

## Consequences

**Good**

- No sync client to keep alive against a hostile API; the catalogue code is a file importer.
- The tab degrades in steps: without the catalogue it is still setup, own routes, lighting and sends.
  Removing a board's catalogue is one allow-list line, not a redesign.
- Issues 1 to 5 depend on neither #1045 nor #1046.

**Bad, and accepted**

- Kilter's main catalogue is about 85 MB to download and around 200 MB on disk (the published file is
  217 MB unpacked; issue 10 measures ours); the hardware map is a 36 MB download from which a few
  megabytes are kept.
- Routes are as fresh as the last snapshot, not live.
- If Boardsesh stops publishing, new Kilter and Tension setups cannot be made and catalogues stop
  updating; existing setups, routes and sends keep working. The fallback then is a hardware map
  shipped in the app, which is a new owner decision.
- The user's old Kilter or Tension logbook is not imported in v1.
- A snapshot in a format the importer does not know is refused and the old catalogue kept; the fix is
  an app update.
- MoonBoard's "Pro" control box (a different, PIN-protected protocol) is not supported; the link
  reports it as unsupported.

### Legal risk that remains

- **Contract.** Sendmeter accepts no maker's terms, so the clauses above do not bind it. A *user* who
  lights a Tension board from Sendmeter may be breaking the Aurora terms they accepted ("only connect
  … through the Apps"). Settings says plainly that Sendmeter is not affiliated with the makers.
- **Copyright in the catalogue.** A climb is a list of hold positions; the makers hold only a
  non-exclusive licence (Aurora) or none found (Moon). Boardsesh and a lawyer consulted by BoardLib's
  maintainer both concluded there is no basis for a claim. That is their view, argued from US law and
  untested in court; a maker can still send a demand.
- **Aurora.** It is the maker most likely to complain, and it has. Tension is the exposed board. If the
  owner wants less exposure, turn Tension's catalogue off and keep its lighting and own routes.
- **Provenance of the protocol facts.** The public specs were derived by others from the makers' apps.
  Sendmeter implements published facts and decompiles nothing.

### App Store review risk

| Guideline | Risk | What we do |
|---|---|---|
| 5.2.2 third-party services: "ensure that you are specifically permitted to do so … Authorization must be provided upon request" | The main one. We cannot show a maker's authorization for the catalogue. | The binary contains no third-party data and calls no maker service; the catalogue is a user-started download of public files. If Apple asks, ship with the allow-list empty: the tab still works. |
| 5.2.1 trademarks | Board names in the app | Names appear only as plain text to say what hardware it works with. No logos, no maker images, no maker colours as branding. |
| 4.1(c), 2.3.7 names and metadata | A maker's name in our name or keywords | Never in the app name, subtitle, keywords, icon or screenshot captions. The description may say "Works with …" once, with the not-affiliated line. |
| 2.1 completeness: reviewer has no board | Rejection for an untestable feature | Reviewer notes explain the hardware and attach a demo video; own routes and the catalogue are usable without a board. |
| 5.1.1 purpose strings | The Bluetooth string names only the force gauge | Reworded in issue 5 to cover board lights. |
| Complaint after release | A maker files an App Store dispute | Same lever as 5.2.2: an update with that board's catalogue off. |

### Owner actions (not blocking the first issues)

- Answer open questions 1 and 2.
- Optional but useful for 5.2.2: write to Kilter, Aurora (for Tension) and Moon asking permission to show
  routes, and tell the Boardsesh maintainers Sendmeter uses the snapshot files.
- Record the reviewer demo video on a real board before the first submission with the tab.

## Hot files

This design converts no existing file. It keeps the board work out of the shared ones instead:

- `Models.swift`, `AppModel.swift` and `SendmeterNativeApp.swift` are edited once (issue 6, the tab).
  Board types live in `BoardCore`; board state lives in `BoardModel`.
- CI is split per area: the new package gets its own workflow file,
  `.github/workflows/board-core.yml`, and its own `just board-core` recipe, not a new job inside
  `native-swift.yml`.
- Docs are split per area: everything about boards stays in `docs/architecture/boards/`.
- The list of supported boards is a folder: one `BoardDescriptor` file per board in
  `native-plugins/board-core/Sources/BoardCore/Boards/`, so a new board (spray wall next) adds a file.

There is no `.drover/arch.toml` on staging yet (#1049 adds it). When it exists, issue 1 adds exactly:

```toml
[[collect]]
dir = "native-plugins/board-core/Sources/BoardCore/Boards"
glob = "*.swift"
```

No `frozen` or `generated` line is needed: no old list is replaced and no file is generated.
