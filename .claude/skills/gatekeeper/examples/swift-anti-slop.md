# swift/anti-slop: what a failure looks like

Each case is one change on the pack's fixture repo. `gatekeeper selftest` runs every case and fails unless the gate fails on it printing the line shown, so these examples cannot go stale.

## extra-explicit-access

Writes `.gatekeeper/config.toml`:

```
packs = ["swift"]
integration = "staging"
pin = "checkout"

[swift]
packages = ["."]
sources = ["Sources"]
tokens = ["Sources"]
extra = ["explicit-access"]
```

Writes `Sources/App/Case.swift`:

```
struct Plain {}
```

The gate fails and its log prints `[explicit-access]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## extra-no-any

Writes `.gatekeeper/config.toml`:

```
packs = ["swift"]
integration = "staging"
pin = "checkout"

[swift]
packages = ["."]
sources = ["Sources"]
tokens = ["Sources"]
extra = ["no-any"]
```

Writes `Sources/App/Case.swift`:

```
public let values: [Any] = []
```

The gate fails and its log prints `[no-any]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## extra-no-comments

Writes `.gatekeeper/config.toml`:

```
packs = ["swift"]
integration = "staging"
pin = "checkout"

[swift]
packages = ["."]
sources = ["Sources"]
tokens = ["Sources"]
extra = ["no-comments"]
```

Writes `Sources/App/Case.swift`:

```
// the row height
public let rowHeight = Layout.row.height
```

The gate fails and its log prints `[no-comments]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## extra-off-by-default

Writes `Sources/App/Case.swift`:

```
// the row height
let rowHeight = Layout.row.height
```

The gate passes.

## extra-sorted-imports

Writes `.gatekeeper/config.toml`:

```
packs = ["swift"]
integration = "staging"
pin = "checkout"

[swift]
packages = ["."]
sources = ["Sources"]
tokens = ["Sources"]
extra = ["sorted-imports"]
```

Writes `Sources/App/Case.swift`:

```
import Foundation
import Dispatch

public let queue = DispatchQueue.main
```

The gate fails and its log prints `[sorted-imports]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-any-dictionary-value

Writes `Sources/App/Case.swift`:

```
let metadata: [String: Any] = [:]
```

The gate fails and its log prints `[no-any-dictionary-value]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-any-parameters

Writes `Sources/App/Case.swift`:

```
func handle(input: Any) {}
```

The gate fails and its log prints `[no-any-parameters]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-any-returns

Writes `Sources/App/Case.swift`:

```
func load() -> Any {
    1
}
```

The gate fails and its log prints `[no-any-returns]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-any-typealiases

Writes `Sources/App/Case.swift`:

```
typealias ExternalValue = Any
```

The gate fails and its log prints `[no-any-typealiases]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-as-any-cast

Writes `Sources/App/Case.swift`:

```
let boxed = 1 as Any
```

The gate fails and its log prints `[no-as-any-cast]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-bool-literal-comparisons

Writes `Sources/App/Case.swift`:

```
func enabled(_ flag: Bool) -> Bool {
    flag ? true : false
}
```

The gate fails and its log prints `[no-bool-literal-comparisons]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-chained-type-casts

Writes `Sources/App/Case.swift`:

```
import Foundation

func user(_ payload: NSObject) -> NSString {
    payload as! NSObject as! NSString
}
```

The gate fails and its log prints `[no-chained-type-casts]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-fatal-error

Writes `Sources/App/Case.swift`:

```
func never() -> Never {
    fatalError("unreachable")
}
```

The gate fails and its log prints `[no-fatal-error]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-force-try

Writes `Sources/App/Case.swift`:

```
import Foundation

let decoded = try! JSONDecoder().decode([Int].self, from: Data("[1]".utf8))
```

The gate fails and its log prints `[no-force-try]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-force-unwrap

Writes `Sources/App/Case.swift`:

```
let first = [1, 2].first!
```

The gate fails and its log prints `[no-force-unwrap]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-hardcoded-secrets

Writes `Sources/App/Case.swift`:

```
let apiKey = "sk-live-abc123"
```

The gate fails and its log prints `[no-hardcoded-secrets]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-implicitly-unwrapped-optionals

Writes `Sources/App/Case.swift`:

```
final class Store {
    var cache: [String: Int]!
}
```

The gate fails and its log prints `[no-implicitly-unwrapped-optionals]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-key-value-coding

Writes `Sources/App/Case.swift`:

```
import Foundation

func name(of owner: NSObject) -> Bool {
    owner.value(forKey: "name") != nil
}
```

The gate fails and its log prints `[no-key-value-coding]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-known-value-widening

Writes `Sources/App/Case.swift`:

```
let payload: Any = ["a": 1]
```

The gate fails and its log prints `[no-known-value-widening]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-runtime-type-sniffing

Writes `Sources/App/Case.swift`:

```
func kind(of value: Int) -> String {
    String(describing: type(of: value))
}
```

The gate fails and its log prints `[no-runtime-type-sniffing]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-shape-in-symbol-names

Writes `Sources/App/Case.swift`:

```
struct UserShape {
    let id: String
}
```

The gate fails and its log prints `[no-shape-in-symbol-names]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-swallowed-errors

Writes `Sources/App/Case.swift`:

```
func step() throws {}

func run() {
    do {
        try step()
    } catch {}
}
```

The gate fails and its log prints `[no-swallowed-errors]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## no-widen-then-assert

Writes `Sources/App/Case.swift`:

```
func load() -> Int { 1 }

func run() -> Int {
    let stored: Any = load()
    return stored as! Int
}
```

The gate fails and its log prints `[no-widen-then-assert]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`

## require-safety-comment-for-forced-cast

Writes `Sources/App/Case.swift`:

```
func id(_ value: Int?) -> Int {
    value as! Int
}
```

The gate fails and its log prints `[require-safety-comment-for-forced-cast]`.

Fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off. Rerun: `./.gatekeeper/run check --gate swift/anti-slop`
