# ADR: Board tab — own-data import, lighting, sends (#1047)

## Summary

Decision: The Board tab sets up your wall, brings in your own logbook and routes from a file the maker sends you, lights a route and logs sends. It never contacts a maker or Boardsesh, uses none of their files, shares nothing between users, and keeps everything on the phone and in your private iCloud. No maker app has an export button, so the file comes by email request: Aurora (Tension, and old Kilter accounts) sends one JSON file, Moon sends spreadsheet files, and the new Kilter app has no known file yet, so it gets no import in v1. A logbook file names climbs but has no holds: your history shows at once, and a route can be lit once it is one you set or you have marked its holds. Which light sits behind which hold comes from a short wiring rule we write from each maker's public installation guide, proven on your wall by a one-minute check in setup; if the check fails you teach the app your wall, and until then nothing is lit.
Slices: a pure board package (types, the two lighting formats, connection logic, wiring rules and check, the two file readers); the Bluetooth link; the tab with setup, own routes, lighting and sends; the import screen; release paperwork. Fifteen issues.
Open questions: (1) Which real boards can you reach to test on? A board's wiring rule is only called checked after a real wall confirms it. (2) Can you ask Aurora and Moon for your own export now? The two file readers are designed from second-hand descriptions and each needs one real file to finish; replies can take weeks.

Status: proposed, revision 2, 2026-11-22. This is an engineering risk assessment, not legal advice.

## Question

How does Sendmeter light Kilter, Tension and MoonBoard walls, hold the user's own routes and logbook,
and log sends, using no maker server, no Boardsesh file and no sharing between users?

## Owner decisions this revision applies

- No Boardsesh files and no maker servers (amendment 1, q2982, q2983).
- No route sharing. Import the user's own routes and logbook from a file; light; log. Device and private
  iCloud only (amendment 2, q2985).
- Say how a user gets their data out of each maker, the format, and how the phone reads it; import the
  logbook in v1; say where each hold-to-LED map comes from and what lights without one (amendment 3,
  q3007).

Revision 1's catalogue download, hardware-map download and their owner gate are removed.

## What the research found

Checked 2026-11-22. Links are to the makers' own pages unless marked.

### The platforms today

- **Kilter left Aurora.** Aurora switched off its Kilter server on 2026-03-26; Kilter now runs its own app
  and backend ([Climbing, 2026-03-31](https://www.climbing.com/news/why-the-kilter-board-app-suddenly-disappeared/)).
  The two are in court in British Columbia (*Aurora Climbing Inc. v. Kilter, LLC*, 2026 BCSC 290).
- **Tension is still an Aurora app.**
- **Terms.** Aurora's [Terms of Use](https://tensionboardapp2.com/terms-of-use) (2023-02-27): "You may
  only connect to the Aurora Products using the Services, as provided through the Apps"; no reverse
  engineering; users grant Aurora a *non-exclusive* licence to their climbs. Kilter's
  [Terms](https://kilterboard.io/terms) (2026-03-09): no access "using a method other than the interface
  and the instructions that we provide", no scraping, no right to "the Kilter name and logo". Moon
  publishes no app terms; its [FAQ](https://moonclimbing.com/using-moonboard-app) refuses access to its
  dataset. A direct client is forbidden or not offered on all three, which is why none is built.

### Getting your own data out

No in-app export was found in any of the three apps.

| | Tension, and old Kilter (Aurora) accounts | New Kilter app (since March 2026) | MoonBoard |
|---|---|---|---|
| In-app export | none | none | none |
| How to ask | Email `support@auroraclimbing.com` with your username and account email | Email `management@kiltergrips.com` | Email `moonboardsupport@moonclimbing.com` |
| Why they answer | Aurora's [Privacy Policy](https://tensionboardapp2.com/privacy-policy) s.7 promises access on written request (BC and Canadian privacy law); it "may charge a reasonable fee". Kilter's own [Claim Data](https://kilterboard.io/claim) page tells its users to do exactly this | Kilter's [Privacy Policy](https://kilterboard.io/privacy): access by email, free; European and UK residents also get a "structured, commonly used and machine-readable" copy. It says no US state privacy law applies to it | [Privacy policy](https://moonclimbing.com/privacy-policy-cookie-restriction-mode): the UK GDPR right to "request access to the personal information we hold about you"; the law gives one month. Moon's [app notice](https://eu.moonclimbing.com/News/post/moonboard-app-update-important-information): "Logbooks and lists are safely stored on our remote servers" |
| What arrives | One `.json` file ("Accepts .json files up to 6MB", Kilter's claim page) | Unknown: no file seen or described | `.csv` files built by hand, one per kind of data |
| What is inside | Sends and attempts (climb *name*, angle, date, grade, tries, stars); the climbs *you* set, with every hold as an x, y and a role; circuits; likes | Unknown | Logbook rows: problem *name*, grade, tries, date, setup, angle, setter, benchmark, comments. No holds |
| Seen by us | No. Fields are second-hand, from an open-source importer's schema | No | No. Columns are second-hand, same way |
| v1 | **Reader** | **No reader**; the tab shows how to ask | **Reader** (logbook) |

How the phone reads it: the user saves the email attachment to Files, taps Import in the Board tab and
picks it in the system file picker. A pure parser turns the bytes into a preview (how many sends, how
many routes, what was skipped and why); nothing is written until the user confirms. No network is used.
Field-level detail is in `imports.md`.

### Where the hold-to-LED map comes from

A controller lights LED number *n* on its string. The map says which hole LED *n* sits behind. That is
the order the strings were threaded through the wall, and each maker prints it for installers.

| Board | Maker's public document | What it shows | Confidence |
|---|---|---|---|
| MoonBoard | Moon's LED System installation guide (V4 2024, V5 2026) | First LED at A1, then a zig-zag up and down the columns; 200 LEDs, 134 on a Mini | High: one formula, long public, in `protocols.md` |
| Tension Board 2 | Aurora's LED Kit Installation Instructions, one per size (8x10, 8x12, 12x10, 12x12, 12x16), page "LED Sequence" | A front view of every hole with the string drawn through it, "Start at the bottom left side of the wall" | Medium: a clear diagram per size, unproven on a wall |
| Kilter | Kilter's [installation handbooks](https://settercloset.com/pages/kilter-board-installation-handbooks), "LED Layout Map" per layout (Homewall 7x10, 8x12, 10x10, 10x12; Original 7x10, 8x12, 12x12, 16x12) | A front view with numbered columns and rows, Start and End, and two colour-coded strands | Lowest: two strands and two LED holes per hold; which index lights which hole must be proven per layout. Read this round: 7x10 Mainline only |
| Original Tension Board | Installation guide found; no LED sequence page read | — | None: taught by the user in v1 |

Sendmeter ships no copy of these documents. A developer reads the diagram and writes the threading
order as a few lines of rule ("start bottom left, run up the first column, down the next"). The rule
is a guess until a wall confirms it, so setup ends with a wiring check.

### Other facts kept from revision 1

- Trademarks: MOONBOARD (US Reg. 5758089) and KILTER (US Reg. 7718567) are registered.
- A third-party app that lights all three boards is on the App Store, described as "Works with Kilter,
  Tension, MoonBoard…" and "not affiliated with or endorsed by any board manufacturer".

## Options

| | Option | Outcome |
|---|---|---|
| A | Direct client to the makers' servers with the user's login | Rejected: both terms forbid it; needs the user's maker password |
| B | Boardsesh's public route and hardware files | Rejected by the owner (amendment 1) |
| C | Routes shared between Sendmeter users through iCloud's public database | Rejected by the owner (amendment 2) |
| D | User-entered routes only | Kept: it is how any route becomes lightable |
| E | Import the user's own data from a file the maker sends them | **Chosen**, with D |
| F | Copy the LED tables out of a maker's app or its database | Rejected: that is the reverse engineering both terms forbid |
| G | LED order as a rule written from the maker's installation guide, confirmed on the wall, taught by the user as a fallback | **Chosen** |

## Decision

1. **No outside service.** The Board feature makes no network request: no maker, no Boardsesh, no
   Sendmeter server. It has no download client. Help text may open the user's own mail app with a draft
   request addressed to the maker; Sendmeter sends nothing.
2. **Every route is a user record.** It was either set in Sendmeter or imported from the user's file.
   There is no catalogue, no search across other people's climbs, no sharing.
3. **Import is a pure reader plus a confirm step.** Two readers in v1: the Aurora export (the user says
   whether it is their Tension or their Kilter file) and Moon's logbook CSV. Import is idempotent: each
   row gets an id derived from its own content, so importing the same or a newer file twice adds nothing
   twice. The new Kilter app gets a reader when a real file has been seen.
4. **A route's holds are either marked or unknown.** A logbook row for someone else's climb arrives as
   a name-only route: it shows in the logbook with its sends and cannot be lit. The user can mark its
   holds once; from then on it lights. Climbs the user set arrive with holds when the file's coordinates
   can be placed on the wall; otherwise they too arrive name-only.
5. **The LED map belongs to the wall.** Each `BoardSetup` stores how its LEDs are ordered: a shipped
   rule the wiring check confirmed, or a table the user taught. Lighting refuses to run on an
   unconfirmed map. A wrong hold lit is worse than no light.
6. **What lights with no map:** only the wiring check's own probe LEDs. Routes are drawn on screen and
   the Light button says what is missing.
7. **Lighting is a pure package.** `BoardCore` (Foundation only) holds both encoders, the link state
   machine, the wiring rules and check, and the file readers, tested on the host and on Linux. One
   CoreBluetooth class serves both board families. No code is copied from any other project.
8. **Setup is one user record per wall:** board, layout, angle, LED map. The Bluetooth peripheral and
   the "current wall" pointer are device-local.
9. **A send is a logbook record** carrying a snapshot of its route, so it reads the same whether the
   route is later edited or deleted. It links to the session by `sessionID` when a workout is live.
   Imported sends are the same type, marked with where they came from.
10. **Storage.** Setups, routes and sends live in the local-first store (#1045) and sync to the user's
    private iCloud database when the user turns sync on. Nothing goes to a public database.
11. **The board is drawn, not pictured.** Holes are dots on a grid with the maker's own column and row
    labels. No maker photo, hold image or logo is shipped.

Details: `data-shapes.md`, `statecharts.md`, `protocols.md`, `imports.md`; modules and issues in `README.md`.

## Consequences

**Good**

- Nothing in the app depends on a maker's server or on a volunteer project staying online.
- No third-party data is in the binary or downloaded by it. The App Review and legal exposure of
  revision 1's catalogue is gone.
- The first seven issues need neither #1045 nor #1046.

**Bad, and accepted**

- **No catalogue.** A Kilter or Tension user cannot browse the maker's climbs in Sendmeter. To light
  someone else's climb they mark its holds once, reading them from the maker's app.
- **Import waits on the maker.** Getting the file means an email and a wait; Aurora may charge a fee;
  Moon builds its files by hand, so columns drift (the reader finds columns by name and reports rows it
  cannot read instead of failing the file).
- **New Kilter accounts cannot import in v1.**
- **The readers are unproven.** No real file was available. Each reader issue starts from a real file
  (open question 2); the field lists in `imports.md` are corrected from it.
- **Own climbs may arrive without holds.** Placing the Aurora file's x, y on a wall needs that layout's
  coordinate rule, which needs a real file and a real wall. Until proven for a layout, its climbs
  import name-only.
- **Wiring rules are unproven.** Each layout's rule ships marked "from the guide" and becomes "checked"
  only when a real wall confirms it (open question 1). A layout with no rule works through teaching,
  which is slow on a big wall (one tap per probe; every LED in the worst case).
- Hold shapes are not shown: the board is a grid of dots.
- MoonBoard's "Pro" control box (a different, PIN-protected protocol) is reported as unsupported.

### Legal risk that remains

- **Lighting.** Sendmeter accepts no maker's terms. A *user* who lights a Tension wall from Sendmeter
  may be breaking the Aurora terms they accepted ("only connect … through the Apps"). Settings says
  plainly that Sendmeter is not affiliated with the makers.
- **Protocol facts.** The two wire formats in `protocols.md` were worked out by others from the makers'
  apps and published; revision 1 read them from public write-ups, Boardsesh's protocol notes among
  them. Sendmeter writes its own encoder, ships and downloads nothing of theirs, and decompiles nothing.
  Aurora is the maker most likely to object, and its dispute with Kilter is about controller technology.
- **The user's own data.** The user holds the rights to their sends and to climbs they set (Aurora
  takes only a non-exclusive licence), obtains the file under their own access rights, and Kilter
  itself directs users to this route. Names of other setters' climbs appear only as lines in the user's
  own history.
- **Installation guides.** A threading order is a fact about hardware; we restate it as a rule and copy
  no diagram or text.

### App Store review risk

| Guideline | Risk | What we do |
|---|---|---|
| 5.2.2 third-party services | Low now: no maker service is called and no maker data is shipped | Reviewer notes say so in one line; import reads a file the user picks |
| 5.2.1 trademarks | Board names in the app | Plain text only, to say what hardware it works with. No logos, maker images or maker colours as branding |
| 4.1(c), 2.3.7 names and metadata | A maker's name in our name or keywords | Never in the app name, subtitle, keywords, icon or screenshot captions. The description may say "Works with …" once, with the not-affiliated line |
| 2.1 completeness: reviewer has no board | Rejection for an untestable feature | Reviewer notes explain the hardware and attach a demo video; setting a route, the logbook and import (with a sample file in the notes) work without a board |
| 5.1.1 purpose strings | The Bluetooth string names only the force gauge | Reworded in issue 7 to cover board lights |

### Owner actions

- Answer open questions 1 and 2. For 2: one email to Aurora and one to Moon from your own accounts.
- Record the reviewer demo video on a real board before the first submission with the tab.

## Hot files

This design converts no existing file. It keeps the board work out of the shared ones instead:

- `Models.swift`, `AppModel.swift` and `SendmeterNativeApp.swift` are edited once (issue 8, the tab).
  Board types live in `BoardCore`; board state lives in `BoardModel`.
- CI is split per area: the new package gets its own workflow file,
  `.github/workflows/board-core.yml`, and its own `just board-core` recipe, not a new job inside
  `native-swift.yml`.
- Docs are split per area: everything about boards stays in `docs/architecture/boards/`.
- The list of supported layouts is a folder: one file per layout in
  `native-plugins/board-core/Sources/BoardCore/Boards/`, so a new layout or board (spray wall next)
  adds a file.

There is no `.drover/arch.toml` on staging yet (#1049 adds it). When it exists, issue 1 adds exactly:

```toml
[[collect]]
dir = "native-plugins/board-core/Sources/BoardCore/Boards"
glob = "*.swift"
```

No `frozen` or `generated` line is needed: no old list is replaced and no file is generated.
