# Lighting protocols (#1047)

The facts the two encoders in `BoardCore` implement, restated from public documents. Nothing here was
tested on hardware by this ADR: **every line is device-only until an issue reports a real board.**

Sources: Boardsesh's
[Aurora spec](https://github.com/boardsesh/boardsesh/blob/main/docs/boards/AURORA_BLUETOOTH_PROTOCOL_SPEC.md)
and
[MoonBoard spec](https://github.com/boardsesh/boardsesh/blob/main/docs/boards/MOONBOARD_BLUETOOTH_PROTOCOL_SPEC.md)
(Apache-2.0). Implement from this page. Do not copy code from the GPL MoonBoard LED projects.

Both boards are a Nordic UART link the phone only writes to:

| | UUID |
|---|---|
| Service | `6E400001-B5A3-F393-E0A9-E50E24DCCA9E` |
| Write characteristic | `6E400002-B5A3-F393-E0A9-E50E24DCCA9E` |

Common transport rules for v1: no pairing or bonding; chunks of at most 20 bytes, written in order, each
after the last was accepted; write with response when the characteristic offers it.

## Aurora wire (Kilter and Tension)

**Finding the board.** It advertises service `4488B571-7806-4DF6-BCFF-A2897E4953FF`. Its name is
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
- **From route to LEDs.** A route's `frames` string is `p<placement>r<role>` repeated. A placement is a
  hold; the hold's LED position depends on the wall's size; the role's colour comes from the hardware
  map. On a mirrored wall the hold is swapped for its mirror before the LED lookup.

Vectors (computed from the rules above; issue 3 also checks them against the spec's worked examples):

| Input | Bytes |
|---|---|
| Level 3, one LED at position 100, colour `00FF00` | `01 04 2B 02 54 64 00 1C 03` |
| Level 2, one LED at position 100, colour `00FF00`, scale 1.0 | `01 03 1B 02 50 64 30 03` |
| Level 3, clear | `01 01 AB 02 54 03` |

## MoonBoard

**Finding the board.** It advertises the UART service; the name starts `MoonBoard` or `Moonboard`.
Older boxes use service `713D0000-503E-4C75-BA94-3148F18D941E` with write characteristic
`713D0003-…`; the link accepts both. A "Pro" control box (service
`7A112233-4455-6677-8899-AABBCCDDEE01`, binary protocol with a PIN) is reported as unsupported.

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

## Unverified, to settle on a real board

- Aurora wire: whether chunks larger than 20 bytes are safe (v1 does not try); the behaviour of a level
  2 box under the power budget.
- MoonBoard: whether `l##` clears a Moon controller (community firmware does); whether a Mini needs
  `~M*`; whether newer controller boxes still accept the ASCII protocol; the write properties of each
  box generation.
- Both: reconnect behaviour and range in a gym with many boards advertising.
