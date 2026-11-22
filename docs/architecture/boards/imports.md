# Importing your own data (#1047)

How a user gets their routes and logbook out of each maker, what the file looks like, and how
`BoardCore` reads it. No reader contacts anyone: it is bytes in, a preview out.

**Nothing on this page was checked against a real file.** The field lists are second-hand (an
open-source importer's published schema, and Kilter's own claim page for the file type). Issues 12 and
13 each start by correcting this page from one real file.

## Getting the file

| Maker | In the app | By request | Arrives as |
|---|---|---|---|
| Aurora: Tension, and Kilter accounts from before March 2026 | no export | Email `support@auroraclimbing.com`: your username and the email on the account, asking for your data export. Aurora's privacy policy (s.7) allows a fee | one `.json`, a few megabytes |
| Kilter's own app | no export | Email `management@kiltergrips.com` asking for access to your personal information (free under its privacy policy; a machine-readable copy for European and UK residents) | unknown |
| Moon | no export | Email `moonboardsupport@moonclimbing.com` asking for a copy of your MoonBoard logbook, the problems you set with their holds, and your lists, under the UK GDPR right of access | `.csv` files |

The import screen shows these steps for the chosen board and a "Write the email" button that opens the
user's mail app with the request drafted. Then: save the attachment to Files, come back, pick it.

On the phone the file is chosen with the system file picker (`.json`, `.csv`), read once through its
security-scoped URL, and never copied or kept. A file over 50 MB is refused before parsing.

## Aurora export (`ImportFormat.auroraExport(board:)`)

One JSON object. The file does not say which board it is for: the user picks Tension or Kilter.

| Key | Each entry | Becomes |
|---|---|---|
| `ascents` | `climb` (name), `angle`, `climbed_at`, `created_at`, `count`, optional `tries`, `grade`, `stars`, `is_mirror`, `is_ascent` | a `Send`, `.sent`; `.attempted` when `is_ascent` is false (the Tension-era file lists attempts here) |
| `attempts` | `climb`, `angle`, `climbed_at`, `created_at`, `count`, optional `is_mirror` | a `Send`, `.attempted` |
| `climbs` | `name`, `layout` (a layout *name*), `created_at`, optional `is_draft`, `description`, `holds`: `x`, `y`, `role` | a `Route` the user set |
| `circuits`, `likes` | names of climbs | not imported in v1; counted in the preview |
| `user` | `username`, optional `email_address` | `username` becomes `setter` on the user's own climbs; the email is not read |
| `follows`, `walls`, `blocks`, `beta_links`, `agreements` | — | ignored |

Rules:

- A send's route is matched to one of the file's `climbs` by name. No match: a name-only route, one
  per distinct climb name, shared by all its sends.
- **Placing holds.** `x`, `y` are positions in the layout's own coordinates. `AuroraCoordinates` turns
  them into grid cells with one rule per layout family (origin and step). A family with no proven rule,
  a hold that lands on no hole, or a `role` string the reader does not know: the climb is imported
  name-only and listed in the preview with the reason.
- The climb's `layout` name picks the layout family; the size is the user's setup. Holds outside that
  size make the route "does not fit this wall": kept, not lightable there.
- `grade` is read as a Font or V label. An unreadable label keeps the send, with no grade, and the
  text goes into the send's note.
- Unknown keys are ignored; a missing optional key is fine; a wrong type on a required key skips that
  entry, not the file.

## Moon logbook CSV (`ImportFormat.moonLogbookCSV`)

Moon builds these by hand, so nothing is read by position.

- **Encoding:** UTF-8 if the bytes are valid UTF-8, else Windows-1252.
- **Header:** found by name, ignoring case, spaces and punctuation. Needed: a problem name, a grade, a
  date. Read when present: tries, setup (`MoonBoard 2016` …), configuration (`40° MoonBoard` gives the
  angle), setter, benchmark, comments, rating.
- **Rows:** each becomes a `Send` and links to a name-only route (name, setter, grade, setup). A tries
  value meaning a project or a fail becomes `.attempted`; a flash is `.sent(tries: 1)`; "more than 3"
  is `.sent(tries: 4)`.
- A row with no readable date or name is skipped and listed. Characters Moon's export replaced with
  `?` are kept as they are.
- Moon's files for problems the user set, and for lists, have not been described anywhere: v1 does not
  read them and says so when one is picked.

## Idempotence

Every imported record's id is derived from its content by a fixed hash in `BoardCore` (no new
dependency):

| Record | Key hashed |
|---|---|
| Send | format, board, climb name, angle, `climbed_at`, sent or attempted |
| Route the user set | format, board, layout name, climb name, `created_at` |
| Name-only route | format, board, climb name |

Applying a plan is an upsert by id. Importing a newer file adds only what is new. A record the user
edited after import is not overwritten: the plan carries only records whose id is absent. Deleting an
imported send and importing again brings it back; the preview says how many records are new.

## What import never does

- No network request, no maker login, no write to a maker account.
- No route from another setter gets holds from anywhere but the user's own marking.
- Nothing is shared: records go to the same store as every other Sendmeter record.
