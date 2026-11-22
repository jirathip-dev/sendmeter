# Statecharts (#1047)

Four pieces of state matter. Each is a pure reducer with host tests; the screens only render them.

## 1. The board link

`BoardLinkMachine` in `BoardCore`. Events come from CoreBluetooth callbacks and from the user;
commands go back to `BoardBluetooth`. The machine never awaits: it takes one event and returns
commands, so no decision is made from a value captured before a suspension.

```mermaid
stateDiagram-v2
    [*] --> Unavailable
    Unavailable --> Idle: radio on and allowed
    Idle --> Unavailable: radio off or denied
    Idle --> Scanning: scan
    Scanning --> Idle: stop / timeout
    Scanning --> Connecting: pick board
    Idle --> Connecting: reconnect known board
    Connecting --> Ready: write characteristic found
    Connecting --> Unsupported: no known write characteristic
    Connecting --> Interrupted: failed / timeout
    Ready --> Sending: light or clear
    Sending --> Sending: chunk written, more to go
    Sending --> Ready: last chunk written
    Sending --> Interrupted: write failed / link dropped
    Ready --> Interrupted: link dropped
    Interrupted --> Connecting: retry
    Interrupted --> Idle: give up / disconnect
    Unsupported --> Idle: dismiss
    Ready --> Idle: disconnect
```

```swift
public enum BoardLinkState: Equatable, Sendable {
    case unavailable(RadioProblem)
    case idle
    case scanning(found: [DiscoveredBoard])
    case connecting(DiscoveredBoard.ID)
    case ready(LinkTraits)
    case sending(LinkTraits, remaining: Int)
    case interrupted(LinkDrop)
    case unsupported(UnsupportedBoard)
}
```

Rules the tests pin:

- **One frame at a time, latest wins.** A `light` that arrives while `Sending` replaces any waiting
  request and starts only after the frame in flight has written its last chunk. Chunks of two frames
  never interleave.
- **A token names each request.** A write callback carrying an old token is ignored.
- **A drop clears the queue.** Nothing is replayed on reconnect unless the user asks; the board keeps
  showing what it last received.
- **Write type is chosen once per connection** from the characteristic's properties: with response
  when offered, without response (paced by the system's ready signal) only when it is the sole option.
- `Unsupported` covers a MoonBoard "Pro" box and any board whose services match nothing known.

## 2. The wiring check (per wall)

`WiringCheck` in `BoardCore`. It decides which LED to light next and what the user's answer means; the
result is the setup's `LEDMapSource`. A probe lights one LED; the user taps the hole that lit on the
drawn board, or "nothing lit".

```mermaid
stateDiagram-v2
    [*] --> Unconfirmed
    Unconfirmed --> Probing: start, layout has a rule
    Unconfirmed --> Teaching: start, layout has no rule
    Probing --> Probing: answer matches, more probes
    Probing --> Confirmed: every probe matched
    Probing --> Fitting: an answer did not match
    Fitting --> Fitting: several orders still fit, probe again
    Fitting --> Confirmed: exactly one order fits
    Fitting --> Teaching: no order fits
    Teaching --> Teaching: hole tapped for this LED
    Teaching --> Confirmed: every hole has its LED
    Confirmed --> Unconfirmed: user reports wrong lights, or changes layout
```

- **Probing** uses the layout's shipped rule and a handful of probes chosen to tell it from its
  near-misses: the first LED, the last, the far end of the first run, each strand's first LED.
- **Fitting** tries the other threading orders (the four start corners, both directions, one or two
  LEDs per hold, an index offset) against every answer so far, and asks for the probe that splits the
  survivors. It ends with one order, stored as `.rule`, or none.
- **Teaching** walks the LEDs in order. After two taps in a line it proposes the rest of that run for
  one tap to accept. The result is stored as `.taught`.
- Progress is part of the state value and is saved with the setup, so leaving the screen or losing the
  link resumes where it stopped. Probes are sent only while the link is `Ready`.
- Until `Confirmed`, `Lighting.plan` returns `.blocked(.wiringUnconfirmed)`: the probes are the only
  thing that lights.
- Every MoonBoard goes through `Probing` too, with two probes: a home wall can be threaded differently
  from the guide.

## 3. An import

`ImportFlow` in `BoardCore`, driven by the import screen.

```mermaid
stateDiagram-v2
    [*] --> Idle
    Idle --> Reading: file picked
    Reading --> Preview: parsed
    Reading --> Failed: not this format / empty / too large
    Preview --> Applying: user confirms
    Preview --> Idle: cancel
    Applying --> Done: plan applied
    Applying --> Failed: store error
    Done --> Idle: close
    Failed --> Idle: close
```

- `Reading` runs off the main actor on the file's bytes; the flow holds a token so a second file picked
  meanwhile replaces the first and a late result is dropped.
- `Preview` shows what is new (records whose id the store does not have), what is already there, and
  each skipped entry with its reason. Nothing is written before `Applying`.
- `Applying` is one store transaction: it ends with everything in the plan added, or nothing.
- Running the same file again reaches `Preview` with nothing new.

## 4. The lit route

Held by `BoardModel`; derived from the link, not stored.

```mermaid
stateDiagram-v2
    [*] --> Dark
    Dark --> Lit: frame fully written
    Lit --> Lit: another route fully written
    Lit --> Dark: clear written
    Lit --> Unknown: link dropped
    Unknown --> Lit: route relit
    Unknown --> Dark: clear written
```

```swift
public enum LitRoute: Equatable, Sendable {
    case dark
    case lit(RouteRef, since: Date)
    case unknown(last: RouteRef)
}
```

- `since` is the moment the last chunk was acknowledged, read from an injected clock. #1048 tags every
  attempt that starts after it with that route, until the next `lit`.
- `unknown` keeps the route for tagging (the board is still showing it) and tells the screen it cannot
  confirm it.
- A wiring-check probe is not a route: it never changes `LitRoute`.
