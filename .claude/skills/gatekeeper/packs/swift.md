# The swift pack

the prebuilt anti-slop-swift, warnings as errors under GATEKEEPER_STRICT=1, the raw colour and size lint

## swift/anti-slop

the prebuilt anti-slop-swift over the [swift] sources: the 19 shared rules always, and the [swift] extra rules the repo switches on

- fix: rewrite the line the rule names: unwrap with guard let, name the real type, bind and handle the error; a // SAFETY: line right above states the invariant a forced operation relies on; a rule is never switched off
- budget: 30s
- cached: yes
- rerun: `./.gatekeeper/run check --gate swift/anti-slop`
- what a failure looks like: [swift-anti-slop](../examples/swift-anti-slop.md)

## swift/tokens

no raw colour or raw size in the [swift] tokens folders but the values and files .gatekeeper/tokens-allowed.txt lists and the shrink-only baseline; runs on any platform

- fix: take the colour or size from a scheme or style token; a value every view may use goes in .gatekeeper/tokens-allowed.txt with its reason; once one is fixed, shrink the list: ./.gatekeeper/run baseline swift/tokens
- budget: 10s
- cached: yes
- rerun: `./.gatekeeper/run check --gate swift/tokens`
- what a failure looks like: [swift-tokens](../examples/swift-tokens.md)

## swift/warnings

each [swift] package's Package.swift treats warnings as errors under GATEKEEPER_STRICT=1, then it builds with its tests under that flag; each [swift] Xcode project builds with warnings as errors

- fix: fix the warning the compiler names; a package's Package.swift adds -warnings-as-errors to its targets when GATEKEEPER_STRICT is 1
- budget: 360s
- cached: yes
- rerun: `./.gatekeeper/run check --gate swift/warnings`
- what a failure looks like: [swift-warnings](../examples/swift-warnings.md)
