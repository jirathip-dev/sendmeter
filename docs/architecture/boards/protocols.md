# Lighting protocols and LED order (#1047)

The facts the two encoders and the wiring rules in `BoardCore` implement. Nothing here was tested on
hardware by this ADR: **every line is device-only until an issue reports a real board.**

Provenance: the two wire formats are facts others worked out and published; revision 1 of this page
restated them from public write-ups, Boardsesh's protocol notes among them. The LED orders come from
the makers' own installation guides. **Implement from this page only.** Copy no code, table or file
from any other project, and take none of their data.

Identifiers on this page are written in groups separated by spaces; in code they take the usual dashes.

Both boards are a Nordic UART link the phone only writes to:

| | Identifier |
|---|---|
| Service | `6E400001 B5A3 F393 E0A9 E50E24DCCA9E` |
| Write characteristic | `6E400002 B5A3 F393 E0A9 E50E24DCCA9E` |

Common transport rules for v1: no pairing or bonding; chunks of at most 20 bytes, written in order, each
after the last was accepted; write with response when the characteristic offers it.

## Aurora wire (Kilter and Tension)

**Finding the board.** It advertises service `4488B571 7806 4DF6 BCFF A2897E4953FF`. Its name is
`<display name>#<serial>@<API level>`, for example `Kilter Board#751737@3`. No `@n` means level 2. A bare
name with no `#serial@level` is a 2025 Kilter-built box: level 2, write with response only.

**A packet** wraps a body of at most 255 bytes:

```
01  <body length>  <checksum>  02  <body…>  03
checksum = bitwise NOT of (sum of body bytes mod 256)
```

**The body** is one command byte, then the LEDs.

| | Level 3 | Level 2 |
|---|---|---|
| Command: only packet | `T` 84 | `P` 80 |
| Command: first of several | `R` 82 | `N` 78 |
| Command: middle | `Q` 81 | `M` 77 |
| Command: last | `S` 83 | `O` 79 |
| Bytes per LED | 3 | 2 |
| LED bytes | position low, position high, colour | position low, colour with position bits |
| Colour byte | `(r/32)<<5 \| (g/32)<<2 \| (b/64)` | `(r>>6)<<6 \| (g>>6)<<4 \| (b>>6)<<2 \| (position>>8 & 3)` |
| Highest position | 65535 | 1023 |
| LEDs per packet | 84 | 127 |

- A route that fits one packet uses "only". Otherwise the first packet is "first", the last is "last",
  the rest "middle". The packets are concatenated and then cut into 20-byte chunks.
- An empty "only" packet clears the board.
- **Level 2 power budget.** Before encoding, pick the first scale in
  `1.0, 0.8, 0.6, 0.4, 0.2, 0.1, 0.05` for which `ledsPerHold × Σ((r+g+b)/30) ≤ 18`, where r, g and b
  are each LED's two-bit values `floor(value × scale) / 64`. Level 3 does no scaling. If no scale fits,
  or the fitting scale turns every LED off, the encoder returns `tooManyLamps` instead of sending a
  dark frame.
- **From route to LEDs.** Each marked hold is a grid cell; the wall's `LEDMap` gives the LED or LEDs
  behind it; the role's colour comes from the board descriptor. The encoder sees only positions and
  colours.

Vectors (computed by hand from the rules above; issue 3's tests recompute them):

| Input | Bytes |
|---|---|
| Level 3, one LED at position 100, colour `00FF00` | `01 04 2B 02 54 64 00 1C 03` |
| Level 2, one LED at position 100, colour `00FF00`, scale 1.0 | `01 03 1B 02 50 64 30 03` |
| Level 3, clear | `01 01 AB 02 54 03` |

## MoonBoard

**Finding the board.** It advertises the UART service; the name starts `MoonBoard` or `Moonboard`.
Older boxes use service `713D0000 503E 4C75 BA94 3148F18D941E` with write characteristic
`713D0003 …`; the link accepts both. A "Pro" control box (service
`7A112233 4455 6677 8899 AABBCCDDEE01`, binary protocol with a PIN) is reported as unsupported.

**The message** is ASCII, no checksum:

```
l#<type><index>,<type><index>,…#
```

| Type | Role | Colour on the board |
|---|---|---|
| `S` | start | green |
| `P` | hand | blue |
| `E` | finish | red |

Optional flags go in front, in this order, comma-separated: `~D*` lights a second LED above each hold
(not for finish holds), `~M*` marks a Mini board, `~D,M*` both. v1 sends `D` from the setup's switch and
`M` for a 12-row board, and does not use the left/right/match/foot letters.

**Hold to LED index.** Columns A to K are 0 to 10; the strip runs up the even columns and down the odd
ones. With `rows` = 18 (standard) or 12 (Mini):

```
index = column × rows + (row − 1)        column even (A, C, E, G, I, K)
index = column × rows + (rows − row)     column odd  (B, D, F, H, J)
```

Vectors:

| Board | Hold | Index |
|---|---|---|
| Standard | A1, A18, B18, B1, C1, K18 | 0, 17, 18, 35, 36, 197 |
| Mini | A1, A12, B12, B1, K12 | 0, 11, 12, 23, 131 |

| Input | Message |
|---|---|
| Standard: start A1, hand B1, finish K18 | `l#S0,P35,E197#` |
| The same with LEDs above holds | `~D*l#S0,P35,E197#` |
| Clear | `l##` |

## LED order per board

The LED position in a frame is the LED's place on the string, counted from the controller. Which hole
that is depends on how the string was threaded, which each maker prints for installers. A layout file
in `Boards/` restates that order as a `WiringRule`; the wiring check proves it on the user's wall.

| Board | Document (the maker's own) | Order it shows | Status |
|---|---|---|---|
| MoonBoard, 18 and 12 rows | LED System installation guide, V4 (2024) and V5 (2026) | First LED at A1, zig-zag by column: the formula above | from the guide; widely confirmed in public |
| Tension Board 2: 8x10, 8x12, 12x10, 12x12, 12x16 | LED Kit Installation Instructions, page "LED Sequence", one document per size | Front view; start at the bottom-left hole; up one column of holes, down the next, to the far side | from the guide |
| Kilter Homewall 7x10 Mainline | Installation handbook, "LED Layout Map" | Front view; columns 1 to 21, rows 7 to 35; Start at column 1 row 7, End at column 21 row 35; two strands, each threaded column by column; two LED holes beside each bolt hole | from the guide; which strand and hole each index lights is unproven |
| Other Kilter layouts (Homewall 7x10 Auxiliary and Fullride, 8x12, 10x10, 10x12; Original 7x10, 8x12, 12x12, 16x12) | The same handbook set, one map per layout | not yet read | issue 6 |
| Original Tension Board | — | none found | no rule: taught by the user |

Rules for issue 5 and 6:

- Write the rule from the diagram: start corner, direction, strands, LEDs per hold, first index. Ship
  no image and no table.
- Every layout file states its document's title and date in its test, and `wiringStatus = .fromGuide`.
- A layout becomes `.checkedOnWall` only in a PR that names the real wall it was confirmed on.

## Unverified, to settle on a real board

- LED order: every rule above, on a real wall of that layout; whether the first LED is index 0.

- Aurora wire: whether chunks larger than 20 bytes are safe (v1 does not try); the behaviour of a level
  2 box under the power budget.
- MoonBoard: whether `l##` clears a Moon controller (community firmware does); whether a Mini needs
  `~M*`; whether newer controller boxes still accept the ASCII protocol; the write properties of each
  box generation.
- Both: reconnect behaviour and range in a gym with many boards advertising.
