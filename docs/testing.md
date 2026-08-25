# Test and coverage gates

The CI quality job runs `npm run test:coverage`. Vitest uses V8 coverage over
the dependency-free logic in `src/lib/**/*.ts`, excluding tests, Supabase
repositories, platform/browser adapters, dynamometer drivers, and generated
or integration seams. The gate checks lines and functions; statements and
branches are reported but intentionally have no floor yet.

The Swift gate is `bash scripts/swift-coverage.sh`. It runs host-only tests
with `swift test --enable-code-coverage`, merges the fresh profiles with
`llvm-profdata`, and checks `llvm-cov` reports for the three pure-logic
packages. Each package is scoped to its own source tree; tests, build output,
generated resource accessors, and the native app's platform/weather adapter
are excluded. Coverage artifacts are written under the ignored `coverage/`
directory and uploaded by CI.

Baselines were measured on 2026-08-25 from the worktree's complete test
suites. Floors are deliberately a small margin below those measurements and
are not rounded up beyond the captured baseline.

| Surface | Line baseline | Line floor | Function baseline | Function floor |
| --- | ---: | ---: | ---: | ---: |
| Web logic | 97.56% (2,964/3,038) | 95% | 95.50% (849/889) | 93% |
| `SendmeterCore` | 91.03% (10,738/11,796) | 89% | 85.35% (1,491/1,747) | 83% |
| `SendLogWatchCore` | 95.93% (3,607/3,760) | 94% | 92.79% (592/638) | 91% |
| `SendLogHealthCore` | 98.75% (237/240) | 96% | 94.44% (51/54) | 92% |

For a local check, run:

```bash
npm run test:coverage
bash scripts/test-coverage-threshold.sh
bash scripts/swift-coverage.sh
```

`scripts/test-coverage-threshold.sh` exercises both below-floor failures and
above-floor success for the shared numeric checker. `Package.resolved` is
backed up and restored by the Swift helper so coverage runs do not commit
SwiftPM's resolution churn. No generated coverage files belong in Git.
