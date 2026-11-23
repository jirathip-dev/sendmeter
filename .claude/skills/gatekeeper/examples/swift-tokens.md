# swift/tokens: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## raw-colour

Writes `Sources/App/Badge.swift`:

```
import SwiftUI

let mark = Text("a").foregroundStyle(Color.red)
```

The gate fails and its log prints `Sources/App/Badge.swift: raw `Color.red` #1`.

Fix: take the colour or size from a scheme or style token; a value every view may use goes in .gatekeeper/tokens-allowed.txt with its reason; once one is fixed, shrink the list: ./.gatekeeper/run baseline swift/tokens. Rerun: `./.gatekeeper/run check --gate swift/tokens`

## raw-size

Writes `Sources/App/Stack.swift`:

```
import SwiftUI

let stack = VStack(spacing: 6) { Text("a") }
```

The gate fails and its log prints `Sources/App/Stack.swift: raw `spacing: 6` #1`.

Fix: take the colour or size from a scheme or style token; a value every view may use goes in .gatekeeper/tokens-allowed.txt with its reason; once one is fixed, shrink the list: ./.gatekeeper/run baseline swift/tokens. Rerun: `./.gatekeeper/run check --gate swift/tokens`

## stale

Writes `.gatekeeper/baseline/swift-tokens.txt`:

```
Sources/App/Stack.swift: raw `spacing: 6` #1
```

The gate fails and its log prints `stale: shrink the baseline (./.gatekeeper/run baseline swift/tokens): Sources/App/Stack.swift: raw `spacing: 6` #1`.

Fix: take the colour or size from a scheme or style token; a value every view may use goes in .gatekeeper/tokens-allowed.txt with its reason; once one is fixed, shrink the list: ./.gatekeeper/run baseline swift/tokens. Rerun: `./.gatekeeper/run check --gate swift/tokens`
